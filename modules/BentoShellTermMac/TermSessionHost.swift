#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoTermLink
import BentoTmuxPane
import BentoWorkbench
import Foundation
import SwiftTmux
import os

/// The shell's one handle on tmux — the client-side successor to
/// `TermDaemonLink`, keeping its API so the view model above it did not have
/// to be rewritten to lose a daemon it never really talked to.
///
/// What actually changed is one layer down. `TermDaemonLink` reached a Go
/// process over a unix socket, which reached tmux; this holds a
/// `TmuxSessionLink` that IS the tmux control client. Everything the old one
/// did through the daemon — structure verbs, the mirror, pane statuses,
/// captures, viewport declarations — tmux does directly, because tmux always
/// was the thing doing them.
///
/// The one genuine loss is the daemon's persistence: nothing keeps reading
/// this tmux server while the app is closed. That is the deliberate trade —
/// Bento Term leaves no process behind on any machine — and it costs nothing
/// here, because the tmux server is the thing that had to survive, and it
/// does, on its own, as it always has.
@MainActor
final class TermSessionHost {
    static let shared = TermSessionHost()

    private static let log = Logger(subsystem: "com.bento.shelltermmac", category: "host")

    private var link: TmuxSessionLink?
    private var authority: TmuxAuthority?
    private var connectTask: Task<Void, Error>?

    /// Last viewport declared, kept only so a link built later starts at the
    /// right size. Re-declaring after a reconnect is the LINK's job — see
    /// `TmuxSessionLink.declareViewport`.
    private var lastViewport: (cols: Int, rows: Int)?

    /// Mirrors the link's phase so the window chrome can show it.
    private(set) var phase: TmuxSessionLink.Phase = .connecting
    var onPhaseChanged: ((TmuxSessionLink.Phase) -> Void)?

    /// The last accepted state — what a late-registering view model adopts.
    private(set) var state: TmuxStructureState?

    private var consumers: [ObjectIdentifier: (TmuxStructureState) -> Void] = [:]

    func register(_ owner: AnyObject, _ handler: @escaping (TmuxStructureState) -> Void) {
        consumers[ObjectIdentifier(owner)] = handler
        if let state { handler(state) }
    }

    func unregister(_ owner: AnyObject) {
        consumers.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// Every session on the server, in list-sessions order.
    var sessions: [TmuxSessionState] { state?.effectiveSessions ?? [] }

    /// The session this control client is on — the one whose panes stream
    /// `%output`.
    var attachedSessionName: String? {
        state?.effectiveSessions.first(where: \.attached)?.name
    }

    // MARK: - Connection

    /// Bring the control client up (idempotent — one per app).
    func start() async throws {
        if link != nil { return }
        if let task = connectTask { return try await task.value }
        let task = Task { try await connect() }
        connectTask = task
        do { try await task.value } catch {
            connectTask = nil
            throw error
        }
    }

    private func connect() async throws {
        let session = TermShell.sessionNames[TermShell.target] ?? TermShell.defaultSessionName
        let transport = TermShell.makeTransport(target: TermShell.target, session: session)
        let link = TmuxSessionLink(
            transport: transport, target: TermShell.target, sessionName: session)
        let authority = TmuxAuthority(link: link)
        authority.onState = { [weak self] state in self?.fanOut(state) }

        // Recovery belongs to the link, which reattaches a fresh transport
        // UNDER ITSELF. This used to drop the pair and build a new link — but
        // every `ControlModeTmuxTransport` holds its link weakly, so the panes
        // stayed wired to the discarded one: output landed nowhere, keystrokes
        // were dropped, and the reconnect still looked like a success.
        link.onPhaseChanged = { [weak self, weak link] phase in
            guard let self, self.link === link else { return }
            self.phase = phase
            self.onPhaseChanged?(phase)
        }

        let size = lastViewport ?? (cols: 120, rows: 40)
        await link.connect(host: Host(), cols: size.cols, rows: size.rows,
                           launch: TermShell.launchStyle, size: .adoptExisting)
        self.link = link
        self.authority = authority
        self.phase = link.phase
        TermShell.paneModule?.isLocalLink = link.isLocalLink
        TermShell.sessionNames[TermShell.target] = session
    }

    private func fanOut(_ state: TmuxStructureState) {
        self.state = state
        for handler in consumers.values { handler(state) }
    }

    // MARK: - Verbs & ops

    /// Ensure a session exists and attach this control client to it.
    /// Switching sessions IS this verb — `switch-client` moves the one
    /// control client, exactly as the daemon's ensure did.
    func ensure(session name: String) async throws {
        try await start()
        guard let link else { throw HostError.notConnected }
        TermShell.sessionNames[TermShell.target] = name
        if link.sessionName != name {
            // -A semantics: attach if it exists, create if it doesn't. Done as
            // two commands because switch-client cannot create.
            let sessions = await link.send(.listSessions)
            let exists = sessions.output
                .split(separator: "\n")
                .contains { $0.split(separator: ":", maxSplits: 1).last.map(String.init) == name }
            if !exists {
                _ = await link.send(.newSessionAt(name: name, cwd: nil))
            }
            _ = await link.send(.switchClient(session: name))
        }
        await link.refreshStructure()
    }

    /// Fire one structure verb; the next snapshot is the answer.
    func apply(_ verb: StructureVerb) {
        authority?.apply(verb)
    }

    /// Apply and await the rev whose state already includes the effect — the
    /// sequenced flows (spread/merge, cross-session moves) ride this.
    @discardableResult
    func applyAwait(_ verb: StructureVerb) async throws -> UInt64 {
        try await start()
        guard let authority else { throw HostError.notConnected }
        return try await authority.applyAwaiting(verb)
    }

    /// The session-size policy lives on the tmux server (`window-size`), which
    /// is why a reconnect has to re-assert it and why one device's choice is
    /// visible to the others. `ownerDevice` is recorded in a user option so a
    /// pinned session can say WHOSE size it is holding.
    @discardableResult
    func setSizePolicy(_ policy: String, ownerDevice: String = "") async throws -> UInt64 {
        try await start()
        guard let link else { throw HostError.notConnected }
        _ = await link.send(.setWindowOption(name: "window-size", value: policy))
        if !ownerDevice.isEmpty {
            _ = await link.send(
                .setSessionOption(name: "@bento_size_owner", value: ownerDevice))
        }
        await link.refreshStructure()
        return state?.rev ?? 0
    }

    /// Fresh per-pane detection inputs for every pane on the server.
    func paneStatuses() async throws -> [TmuxPaneStatus] {
        try await start()
        guard let link else { throw HostError.notConnected }
        return await link.paneStatuses()
    }

    /// One pane's visible screen as plain text — the agent rule engine's
    /// needsSnapshot input.
    func capturePane(_ pane: Int) async throws -> String {
        try await start()
        guard let link else { throw HostError.notConnected }
        let data = await link.capture(pane: TmuxPaneID(pane), lines: 0)
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// Declare this client's viewport. The link remembers it, because
    /// `refresh-client -C` is a property of the CLIENT and a reconnect is a
    /// new client — a size declared before a drop has to be restated after it.
    func declareViewport(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastViewport = (cols, rows)
        link?.declareViewport(cols: cols, rows: rows)
    }

    /// The live link, for the pane transports.
    var sessionLink: TmuxSessionLink? { link }

    enum HostError: LocalizedError {
        case notConnected
        var errorDescription: String? { "Not connected to tmux." }
    }
}
#endif
