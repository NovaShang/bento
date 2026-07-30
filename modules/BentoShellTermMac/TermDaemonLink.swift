#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoLink
import BentoTmuxPane
import BentoWorkbench
import Foundation
import os

/// The ONE control channel the whole shell shares: the local daemon's unix
/// socket carrying the tmux structure mirror in (statekv `statechanged` →
/// `DaemonAuthority.ingest`) and structure verbs out. The daemon holds ONE
/// control client per target, attached to ONE session at a time — switching
/// sessions IS the ensure (`spawn` kind=tmux, idempotent, attaches-or-creates)
/// — while the mirror carries EVERY session on the real default-socket server,
/// which is what the menubar list, the session strip, and every window's
/// structure read from.
///
/// This is the data spine under the frozen `TerminalViewModel` API: where the
/// frozen product held one `tmux -CC` client per session tab, the trunk holds
/// this link; the view models register here and each picks its own session's
/// row out of every accepted mirror state.
@MainActor
final class TermDaemonLink {
    static let shared = TermDaemonLink()

    private static let log = Logger(subsystem: "com.bento.shelltermmac", category: "link")

    private var control: AcpHostTransport?
    private var authority: DaemonAuthority?
    private var connectTask: Task<Void, Error>?
    /// Single-flight background reconnect after the control transport dies.
    private var reconnectTask: Task<Void, Never>?
    /// Last viewport declared on this channel — re-declared after a
    /// reconnect (viewport declarations are per-stream; the daemon forgets
    /// them with the stream).
    private var lastViewport: (cols: Int, rows: Int)?

    /// Serializes EVERY structure frame this app sends: the daemon matches
    /// acks to ops by arrival order on the stream (no correlation id), so a
    /// frame must never pass another between apply() and the wire.
    private var frameChain: Task<Void, Never>?

    /// The last accepted mirror state — what a late-registering VM adopts.
    private(set) var state: TmuxStructureState?

    /// Registered view models (one per session window), fanned the whole
    /// server picture on every accepted mirror rev.
    private var consumers: [ObjectIdentifier: (TmuxStructureState) -> Void] = [:]

    func register(_ owner: AnyObject, _ handler: @escaping (TmuxStructureState) -> Void) {
        consumers[ObjectIdentifier(owner)] = handler
        if let state { handler(state) }
    }

    func unregister(_ owner: AnyObject) {
        consumers.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// Every session on the server, in list-sessions order (empty until the
    /// first mirror value lands).
    var sessions: [TmuxSessionState] { state?.effectiveSessions ?? [] }

    /// The session the daemon's control client is on — the one whose panes
    /// stream %output.
    var attachedSessionName: String? {
        state?.effectiveSessions.first(where: \.attached)?.name
    }

    // MARK: - Connection

    /// Bring the control channel up (idempotent — one connection per app).
    /// The read path starts immediately: statekv still holds the last mirror
    /// value across daemon restarts, so structure is often available before
    /// the first ensure.
    func start() async throws {
        if control != nil { return }
        if let task = connectTask { return try await task.value }
        let task = Task { try await connect() }
        connectTask = task
        do { try await task.value } catch {
            connectTask = nil
            throw error
        }
    }

    private func connect() async throws {
        let transport = AcpHostTransportFactory.local(socketPath: TermShell.socketPath)
        try await transport.connect()
        // The authority is built by hand rather than `.linked` because every
        // frame must ride the ONE serialized chain below (a second chain on
        // the same stream could cross acks), and because `onState` — not the
        // attached-entry projection — is the multi-session read.
        let authority = DaemonAuthority(
            encoding: DaemonStructureVerbEncoding(target: TermShell.target)
        ) { [weak self] frame in
            guard let self else { throw AcpHostError.connectionClosed }
            return try await self.send(frame: frame)
        }
        authority.onState = { [weak self] state in self?.fanOut(state) }
        let key = TmuxStructureDecoding.statekvKey(target: TermShell.target)
        transport.onEvent = { [weak authority, weak transport] event in
            guard case .stateChanged(let changed) = event, changed == key else { return }
            Task { @MainActor in
                guard let authority, let transport,
                      let data = try? await transport.getState(key: key) else { return }
                authority.ingest(stateValue: data)
            }
        }
        // Connection death (daemon restart) must not leave a zombie link:
        // the old shape held the dead transport forever — every verb
        // silently failed, the statechanged subscription was gone, and the
        // whole GUI read as frozen while pane bytes (their own connections)
        // kept flowing. Drop the dead pair and reconnect in the background.
        transport.onClosed = { [weak self, weak transport] in
            Task { @MainActor in
                guard let self, let transport else { return }
                self.handleControlClosed(transport)
            }
        }
        self.control = transport
        self.authority = authority
        if let data = try? await transport.getState(key: key) {
            authority.ingest(stateValue: data)
        }
    }

    private func handleControlClosed(_ transport: AcpHostTransport) {
        guard control === transport else { return }   // superseded already
        control = nil
        authority = nil
        connectTask = nil
        Self.log.warning("control channel lost — reconnecting")
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            var backoff: UInt64 = 500_000_000   // 0.5s → 8s cap
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    try await self.start()
                    // Re-attach the daemon's control client to the session
                    // the user was on (the ensure is the attach), and
                    // restore this stream's viewport declaration.
                    if let name = TermShell.sessionNames[TermShell.target] {
                        try await self.ensure(session: name)
                    }
                    if let viewport = self.lastViewport {
                        self.declareViewport(cols: viewport.cols, rows: viewport.rows)
                    }
                    self.reconnectTask = nil
                    Self.log.info("control channel reconnected")
                    return
                } catch {
                    // Daemon still down — keep trying.
                }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 8_000_000_000)
            }
        }
    }

    private func fanOut(_ state: TmuxStructureState) {
        self.state = state
        for handler in consumers.values { handler(state) }
    }

    // MARK: - Verbs & ops

    /// Ensure a session exists and ATTACH the daemon's control client to it
    /// (`spawn` kind=tmux — attaches-or-creates; switching sessions is this
    /// verb). The mirror republishes before the ack, so callers can read the
    /// fresh picture right after.
    func ensure(session name: String) async throws {
        try await start()
        guard let control else { throw AcpHostError.connectionClosed }
        TermShell.sessionNames[TermShell.target] = name
        _ = try await control.ensureTmux(target: TermShell.target, sessionName: name)
        // The ensure's own refresh may land as statechanged slightly after
        // the ack; pull once so the caller sees the ensured session now.
        let key = TmuxStructureDecoding.statekvKey(target: TermShell.target)
        if let data = try? await control.getState(key: key) {
            authority?.ingest(stateValue: data)
        }
    }

    /// Fire one structure verb (acked in the background; the mirror's next
    /// snapshot is the answer). UI verbs ride this.
    func apply(_ verb: StructureVerb) {
        authority?.apply(verb)
    }

    /// Send one structure verb and await the rev whose mirror value already
    /// includes its effect — the sequenced flows (spread/merge, cross-session
    /// moves, agent-session builds) ride this.
    @discardableResult
    func applyAwait(_ verb: StructureVerb) async throws -> UInt64 {
        try await start()
        let frame = try DaemonStructureVerbEncoding(target: TermShell.target)
            .encodeStructureFrame(verb)
        return try await send(frame: frame)
    }

    /// setSizePolicy travels as a hand-built frame: the verb is deliberately
    /// not in the shared `StructureVerb` vocabulary (product A's authority
    /// switch would have to learn a case it can never mean), and the pinned
    /// OWNER is the issuing stream — this stream.
    @discardableResult
    func setSizePolicy(_ policy: String, ownerDevice: String = "") async throws -> UInt64 {
        try await start()
        var verb: [String: Any] = ["kind": "setSizePolicy", "policy": policy]
        if !ownerDevice.isEmpty { verb["owner_device"] = ownerDevice }
        let frame = try JSONSerialization.data(withJSONObject: [
            "op": "structure", "target": TermShell.target, "verb": verb,
        ])
        return try await send(frame: frame)
    }

    /// Fresh per-pane detection inputs — command + title for every pane on
    /// the server (the `tmuxpanes` op). The state-detection tick's first
    /// half; the structure mirror deliberately never carries these (they
    /// flap without structural meaning and may not mint mirror revs).
    func paneStatuses() async throws -> [AcpTmuxPaneStatus] {
        try await start()
        guard let control else { throw AcpHostError.connectionClosed }
        return try await control.tmuxPanes(target: TermShell.target)
    }

    /// One pane's visible screen as plain text (the `tmuxcapture` op) —
    /// the agent rule engine's needsSnapshot input.
    func capturePane(_ pane: Int) async throws -> String {
        try await start()
        guard let control else { throw AcpHostError.connectionClosed }
        return try await control.tmuxCapture(agentID: "tmux:\(TermShell.target):%\(pane)")
    }

    /// Declare this stream's standing viewport (the session-size authority's
    /// input; no ack — the mirror's `sizing` block is the read path).
    func declareViewport(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastViewport = (cols, rows)
        control?.declareViewport(target: TermShell.target, cols: cols, rows: rows)
    }

    /// One serialized frame → ack. See `frameChain`.
    private func send(frame: Data) async throws -> UInt64 {
        guard let control else { throw AcpHostError.connectionClosed }
        let previous = frameChain
        let task = Task<UInt64, Error> {
            await previous?.value
            return try await control.sendStructureFrame(frame)
        }
        frameChain = Task { _ = try? await task.value }
        return try await task.value
    }
}
#endif
