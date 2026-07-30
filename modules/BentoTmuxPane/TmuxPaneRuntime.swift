import ACPKit
import BentoTerminalPane
import BentoWorkbench
import Foundation

// ACPKit is imported for exactly two type names — `ACPClientHandler` /
// `ACPConnection` in PaneRuntime's establishment face. The blueprint says
// this module imports no ACP anything; the seam as it stands disagrees
// (bootstrap/makeSessionHandler speak ACP vocabulary), and changing the
// seam is off the table this stage (product A's ladder is frozen). Flagged:
// stage 2 either grows PaneRuntime an ACP-neutral establishment face or
// keys the store's ladder off `PaneCapabilities`.

/// One tmux pane as the workspace store steers it — `PaneRuntime` over a
/// `TmuxByteTransport` (docs/tmuxpane-design.md's mapping table):
///
///   send(text)              = bytes + CR      (send-keys submit)
///   insertIntoComposer      = bytes           (send-keys typing)
///   composerDraft           = "" always       (terminals have no draft box)
///   phase                   = attach → ready, exit frame → ended
///   working / awaiting      = output-parse state rules (StateDetectionService)
///   hasCompletedTurn        = the rules' working → idle edge
@MainActor
public final class TmuxPaneRuntime: PaneRuntime {
    public let instanceID: TmuxVirtualInstanceID
    private let transport: any TmuxByteTransport
    private let detection: StateDetectionService

    /// `detection` nil = a private service instance (the default argument
    /// can't construct one: the service is main-actor-isolated).
    public init(instanceID: TmuxVirtualInstanceID,
                title: String = "",
                transport: any TmuxByteTransport,
                detection: StateDetectionService? = nil) {
        self.instanceID = instanceID
        self.title = title
        self.transport = transport
        self.detection = detection ?? StateDetectionService()
    }

    // MARK: - Store-facing callbacks (wired by the pane module's install)

    /// Pane output, one wire unit per call — the surface's `feed`.
    public var onOutput: ((Data) -> Void)?
    /// Any state-language or phase movement (the store's `.activity` fanout).
    public var onActivityChange: (() -> Void)?

    // MARK: - Identity & titles

    public private(set) var phase: PaneRuntimePhase = .starting {
        didSet { if phase != oldValue { onActivityChange?() } }
    }
    /// The pane's display title. Fed by `pane_title` from the structure
    /// mirror (stage 2 wiring); a user rename travels as a structure verb,
    /// never a local write-back.
    public var title: String
    /// tmux has no agent-named conversation; the pane title IS the name.
    public var sessionTitle: String? { nil }
    /// No ACP conversation id exists for a tmux pane.
    public var sessionId: String? { nil }

    /// `pane_current_command`, which detection uses to pick the agent
    /// profile. Stage-2 seam WITHOUT a decided source: the structure
    /// mirror deliberately excludes it (process introspection flaps and
    /// would mint spurious mirror revs — tmuxcm SnapshotPane), so the
    /// reading needs its own channel.
    public var currentCommand: String?

    // MARK: - Catch-up cursor

    /// Output units consumed. Valid as the attach cursor because the daemon
    /// guarantees one log entry per wire unit (tmuxPane.feed).
    public private(set) var updateSeq: UInt64 = 0
    /// A terminal pane's rendered scrollback is exactly the units it
    /// consumed — an honest claim once anything has been fed.
    public var holdsRenderedTranscript: Bool { updateSeq > 0 }

    // MARK: - Attach (the transport-driven establishment path)

    private var attachTask: Task<Void, Never>?

    /// Attach through the byte transport and consume the event stream.
    /// This — not the store's launcher ladder — is how a tmux pane comes
    /// up; see the inert ACP face below.
    ///
    /// The loop is the daemon-restart survival path: when the event stream
    /// ends WITHOUT an exit frame (LinkTmuxTransport finishes it on
    /// connection death), the pane still lives on the tmux server — only
    /// the wire died — so re-attach with the retained cursor, backing off
    /// while the daemon comes back. A stream that ended WITH an exit frame
    /// (`phase == .ended`) is a real pane death and stays down. A FIRST
    /// attach that fails keeps the launch-failure semantics (phase
    /// `.failed`, no retry): auto-retry is only for a wire we know worked.
    public func attach() {
        attachTask?.cancel()
        phase = .starting
        attachTask = Task { [weak self] in
            guard let self else { return }
            var hadAttached = false
            var backoff: UInt64 = 500_000_000   // 0.5s → 8s cap
            while !Task.isCancelled {
                do {
                    let attachment = try await self.transport.attach(haveSeq: self.updateSeq)
                    hadAttached = true
                    backoff = 500_000_000
                    self.noteAttached(attachment.details)
                    for await event in attachment.events {
                        if Task.isCancelled { return }
                        self.consume(event)
                    }
                    if Task.isCancelled { return }
                    if case .ended = self.phase { return }   // exit frame: real death
                    self.phase = .starting                    // wire death: reconnect
                } catch is CancellationError {
                    // Superseded by a restart/shutdown; that path owns the phase.
                    return
                } catch {
                    if !hadAttached {
                        self.noteLaunchFailure(String(describing: error))
                        return
                    }
                    // Re-attach refused (daemon still restarting) — keep trying.
                }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 8_000_000_000)
            }
        }
    }

    /// Re-attach from the start of the daemon's retained log: a freshly
    /// (re)bound surface wants the scrollback replayed, not just the live
    /// tail — the trunk's answer to the frozen product's capture-pane seed
    /// on window switch.
    public func reattachFromStart() {
        updateSeq = 0
        attach()
    }

    /// Units at or below this cursor are an attach's catch-up replay —
    /// HISTORY, not the pane doing something now. Set per attach.
    private var replayBoundary: UInt64 = 0

    private func noteAttached(_ details: TmuxAttachDetails) {
        if details.replay {
            replayBoundary = details.headSeq
        } else {
            // Live-from-head: the daemon isn't resending the gap, so the
            // cursor jumps to the head rather than counting units it will
            // never see.
            updateSeq = max(updateSeq, details.headSeq)
            replayBoundary = 0
        }
        phase = details.running ? .ready : .ended
    }

    private func consume(_ event: TmuxPaneEvent) {
        switch event {
        case .output(let data):
            updateSeq += 1
            // Replayed history feeds the surface and the detection text
            // buffer, but never the ACTIVITY clock — counting it lit every
            // replayed pane "working" for a silence-threshold after each
            // attach/pane switch/reconnect.
            let isReplay = updateSeq <= replayBoundary
            detection.recordOutput(pane: instanceID.pane, data: data,
                                   asActivity: !isReplay)
            onOutput?(data)
            if !isReplay {
                refreshDetectedState()
                scheduleSilenceRecheck()
            }
        case .exit:
            silenceRecheck?.cancel()
            // Direct write, not applyDetectedState: an exit mid-turn is not
            // a completed turn, so the done edge must not fire here.
            detectedState = .idle
            phase = .ended
        }
    }

    // MARK: - Lifecycle verbs (the store's restart/reconnect ladders)

    public func prepareForRestart() {
        attachTask?.cancel()
        attachTask = nil
        silenceRecheck?.cancel()
        detectedState = .idle
        phase = .starting
    }

    public func noteReconnectFailed() {
        phase = .ended
    }

    public func noteLaunchFailure(_ message: String) {
        phase = .failed(message)
    }

    public func killAgent() {
        // Deliberately empty, mirroring the daemon: pane lifecycle belongs
        // to the `structure` op (kill-pane via DaemonAuthority) — a client
        // teardown must not take a tmux pane down by accident.
    }

    public func shutdown() {
        attachTask?.cancel()
        attachTask = nil
        silenceRecheck?.cancel()
        transport.detach()
    }

    // MARK: - State language (output-parse rules; no protocol truth here)

    private var detectedState: BentoTerminalPane.PaneState = .idle

    /// The detection → seam mapping, including the done edge. Package so
    /// tests can drive the edge without waiting out the silence threshold;
    /// production traffic reaches it only through `refreshDetectedState`.
    package func applyDetectedState(_ state: BentoTerminalPane.PaneState) {
        let old = detectedState
        detectedState = state
        if case .working = old, case .idle = state {
            hasCompletedTurn = true   // the done edge
        }
        if state != old { onActivityChange?() }
    }

    public var isTurnActive: Bool {
        if case .working = detectedState { return true }
        return false
    }

    public var isAwaitingUserInput: Bool {
        if case .awaitingInput = detectedState { return true }
        return false
    }

    public var previewLine: String {
        guard isAwaitingUserInput else { return "" }
        return detection.recentText(for: instanceID.pane, lines: 1)
    }

    public var firstUserPromptPreview: String? { nil }
    public private(set) var hasCompletedTurn = false

    /// The screen fetch behind the agent rule engine's needsSnapshot pass:
    /// the daemon's `tmuxcapture` op (plain capture-pane text), plugged in
    /// by the shell. nil = engine runs title-only.
    public var captureScreenText: (() async -> String?)?

    /// Precise agent-state pass — the frozen product's classifyPane ladder,
    /// verbatim in substance: cheap title classification first (a braille
    /// spinner resolves .working with no round-trip, `✳` reads idle);
    /// when the engine needs the screen, fetch it through
    /// `captureScreenText` and re-classify (blocked forms, working
    /// footers). Panes the engine doesn't recognize keep the legacy
    /// output-recency reading. Drive this from the shell's detection tick
    /// with `currentCommand`/`title` freshly fed (the `tmuxpanes` op).
    public func refreshAgentState() async {
        let command = currentCommand
        let title = self.title
        switch detection.classifyAgent(command: command, title: title, snapshot: nil,
                                       pane: instanceID.pane, current: detectedState) {
        case .notAgent:
            refreshDetectedState()
        case .state(let s):
            applyDetectedState(s)
        case .needsSnapshot:
            let snap = await captureScreenText?()
            if case .state(let s) = detection.classifyAgent(
                command: command, title: title, snapshot: snap,
                pane: instanceID.pane, current: detectedState) {
                applyDetectedState(s)
            }
        }
    }

    private func refreshDetectedState() {
        // A recognized agent's state belongs to the rule engine
        // (refreshAgentState, on the shell's tick) alone: the legacy
        // recency reading ("output in the last 5s = working") is exactly
        // what lit every idle claude pane blue, and must not race the
        // engine's verdict between ticks.
        if detection.isRecognizedAgent(command: currentCommand, title: title) { return }
        applyDetectedState(detection.detectState(
            pane: instanceID.pane, currentCommand: currentCommand, title: title))
    }

    /// Re-run detection after the service's silence threshold so a pane
    /// that stops emitting settles from working → idle without waiting for
    /// the next chunk. Mirrors `StateDetectionService`'s (private) 5s
    /// threshold, plus margin.
    private static let silenceRecheckSeconds: TimeInterval = 5.5
    private var silenceRecheck: Task<Void, Never>?

    private func scheduleSilenceRecheck() {
        silenceRecheck?.cancel()
        silenceRecheck = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.silenceRecheckSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshDetectedState()
        }
    }

    // MARK: - Input (send-keys semantics)

    /// Terminals have no draft box: reads are always empty, writes are
    /// dropped. `routeInput`'s CR-submit therefore no-ops — a terminal
    /// submit is `send`, which carries its own CR.
    public var composerDraft: String {
        get { "" }
        set {}   // swiftlint-style: intentionally discarded
    }

    /// The voice compass's SEND: the text plus the CR that executes it.
    public func send(_ text: String) {
        transport.write(Data((text + "\r").utf8))
    }

    /// The voice compass's INSERT: bytes only, no CR — the user keeps
    /// editing at the prompt.
    public func insertIntoComposer(_ text: String) {
        transport.write(Data(text.utf8))
    }

    /// Raw surface keystrokes (already encoded by the terminal engine).
    public func write(_ data: Data) {
        transport.write(data)
    }

    /// Off-main raw write — the input coalescer's flush queue calls this so a
    /// keystroke burst never hops back onto the main actor to reach the wire.
    /// Safe because `transport` is a `let` of a Sendable type and its `write`
    /// is a synchronous, lock-guarded enqueue (LinkTmuxTransport.write).
    public nonisolated func writeRaw(_ data: Data) {
        transport.write(data)
    }

    /// Renderer-authoritative grid → the daemon's `resize` op (the
    /// `.resizable` capability's one verb).
    public func resize(cols: Int, rows: Int) {
        transport.resize(cols: cols, rows: rows)
    }

    // MARK: - Inert ACP establishment face
    //
    // The store's launcher ladder (`performEstablish`) speaks ACP: it asks
    // for a session handler and bootstraps a JSON-RPC connection. None of
    // that exists for a tmux pane — establishment is `attach()` above.
    // These implementations are inert so an accidental trip through the
    // ladder cannot fabricate state; routing the ladder by capability is
    // the flagged stage-2 seam (see the header note).

    public func makeSessionHandler() -> any ACPClientHandler {
        InertTmuxSessionHandler()
    }

    public func bootstrap(connection: ACPConnection, resumeSessionId: String?) async {
        assertionFailure("tmux panes establish via TmuxByteTransport.attach, not the ACP ladder")
    }

    public func bootstrapAttached(launch: AgentLaunch, resumeSessionId: String?) async {
        assertionFailure("tmux panes establish via TmuxByteTransport.attach, not the ACP ladder")
    }
}

/// Never receives traffic (no ACP connection is ever bootstrapped for a
/// tmux pane); exists only because `PaneRuntime` requires a handler.
private struct InertTmuxSessionHandler: ACPClientHandler {
    func sessionUpdate(_ notification: SessionNotification) async {}
    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionOutcome {
        .cancelled
    }
}
