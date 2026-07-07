import Foundation
import SwiftUI
import os
import SwiftTmux

private let log = Logger(subsystem: "com.novashang.bento", category: "TerminalVM")

/// Optional file sink for the core package's `dlog`. Core logs default to
/// os_log only, which is invisible in the app's pullable `debug.log` — set
/// this once at app start (before any terminal work) to mirror every core
/// log line into the host app's file logger so real-device incidents can be
/// diagnosed from a single file pull.
public nonisolated(unsafe) var coreDlogFileSink: (@Sendable (String) -> Void)?

/// Package-local debug log (the app's global `dlog` lives in the iOS target).
func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
    coreDlogFileSink?(s)
}

/// User's choice for how to start a session on the host.
public enum TmuxStartChoice: Hashable {
    /// Don't use tmux — plain shell.
    case noTmux
    /// Create or attach to a session by name (no grouping).
    case createOrAttach(name: String)
    /// Create a grouped session that mirrors `target` (shared with desktop).
    case shareWithDesktop(target: String)
    /// Spin up a detached tmux session matching `spec` (working dir, agent
    /// command, layout), then attach in control mode.
    case createAgent(spec: AgentSpec)
}

/// High-level session phase. Distinct from low-level SSH state.
public enum SessionPhase: Equatable {
    case sshConnecting       // SSH handshake in progress
    case choosingSession     // SSH up; user picking tmux mode
    case starting            // applying choice (e.g. running tmux -CC)
    case shellReady          // non-tmux: plain shell live
    case tmuxReady           // tmux multiplexer live
    case suspended           // app backgrounded; SSH may be dead, tmux still alive on server
    case ended
}

@MainActor
public final class TerminalViewModel: ObservableObject {
    @Published public var connectionState: TerminalConnectionState = .disconnected
    @Published public var errorMessage: String?
    @Published public var showError = false
    /// True while an auto-reconnect loop is in flight (after a drop, or on
    /// foreground resume). Drives a "Reconnecting…" banner so the UI is never
    /// silently frozen — distinct from `phase`, which churns through
    /// `.sshConnecting`/`.starting` during each attempt.
    @Published public var isReconnecting = false
    @Published public var paneViewModels: [PaneViewModel] = []
    @Published public var activePaneID: TmuxPaneID?
    /// The currently zoomed pane (tmux `window_zoomed_flag`), or nil. When set,
    /// the tiled host shows only this pane filling the window.
    @Published public var zoomedPaneID: TmuxPaneID?
    @Published public var windows: [TmuxWindow] = []
    /// Every pane in the session across ALL windows (session-wide `list-panes
    /// -s`), refreshed together with `paneViewModels`. Powers the hierarchical
    /// structure model: window list items, per-window agent status, and the
    /// spread/merge structure ops. `paneViewModels` stays scoped to the current
    /// window (only its panes have live surfaces).
    @Published public private(set) var sessionPanes: [Pane] = []
    /// The session's current window (drives the active tab highlight).
    @Published public var activeWindowID: TmuxWindowID?
    @Published public var isTmuxReady = false

    /// Where we are in the session lifecycle.
    @Published public var phase: SessionPhase = .sshConnecting

    /// Sessions discovered via `tmux ls` after SSH is up.
    @Published public var availableTmuxSessions: [String] = []
    @Published public var sessionsLoading: Bool = false

    /// Incremented on each state poll cycle to trigger SwiftUI re-render
    @Published public var stateVersion: Int = 0

    /// Live agent activity across the current window's panes — drives the macOS
    /// toolbar's center summary ("N working · M waiting"). Counts only recognized
    /// coding-agent panes (claude/codex/…), not plain shells. (tmux -CC streams
    /// the active window only, so background windows aren't included yet.)
    @Published public var agentsWorking: Int = 0
    @Published public var agentsWaiting: Int = 0
    /// Agent panes that finished their turn while unfocused (the "done, unseen"
    /// blue state) — drives the session tab's blue status dot.
    @Published public var agentsDoneUnseen: Int = 0

    public let host: Host
    let transport: TerminalTransport
    let tmuxService = TmuxControlMode()
    public let stateDetection = StateDetectionService()
    let environment: TerminalEnvironment

    /// For non-tmux fallback: direct terminal data callback. Setting this
    /// replays the full history buffer so a re-bound TerminalView repaints
    /// scrollback instead of showing an empty screen until the next byte.
    public nonisolated(unsafe) var onRawDataReceived: (@Sendable (Data) -> Void)? {
        didSet {
            guard let onRawDataReceived, !rawHistory.isEmpty else { return }
            onRawDataReceived(rawHistory)
        }
    }

    /// Rolling buffer of raw shell bytes (non-tmux mode). Capped. Marked
    /// nonisolated(unsafe) so the `onRawDataReceived` didSet (also
    /// nonisolated) can read it — all real access happens on MainActor.
    nonisolated(unsafe) private var rawHistory = Data()
    private static let maxRawHistoryBytes = 256 * 1024

    /// Push predicted keystrokes (Mosh-style local echo) to the surface as a
    /// preedit overlay. Set by the host wiring (raw/no-tmux path only) to the
    /// active surface's `setPredictedText`. See `predictor`.
    public var onPredictionText: ((String) -> Void)?

    /// Predictive local echo for the raw path. Inert unless the feature flag is
    /// on; only ever touches an overlay, never the authoritative grid.
    private lazy var predictor: PredictiveEcho = {
        let p = PredictiveEcho(enabled: Self.predictiveEchoEnabled)
        p.render = { [weak self] text in self?.onPredictionText?(text) }
        return p
    }()

    /// Feature flag (Settings / UserDefaults). Off unless explicitly enabled.
    public nonisolated static var predictiveEchoEnabled: Bool {
        UserDefaults.standard.bool(forKey: "predictive_echo_enabled")
    }

    /// Whether we're using tmux control mode
    nonisolated(unsafe) private(set) var usingTmux = false

    /// Active tmux session name (used for kill-session etc).
    @Published public private(set) var activeTmuxSessionName: String?

    /// Shell-output capture state (for `tmux ls` and similar commands run in
    /// raw shell mode before we hand off to either the terminal or tmux -CC).
    private struct ShellCapture {
        var buffer: Data = Data()
        var marker: String
        var continuation: CheckedContinuation<String, Never>
    }
    private var shellCapture: ShellCapture?

    /// True while we're waiting on a scheduled auto-reconnect attempt. The
    /// onStateChanged hook checks this so an in-flight retry's transient
    /// `.failed` doesn't get treated as a fresh failure (and spawn nested
    /// reconnect tasks).
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// The surface's last reported grid (cols, rows). Used to start the shell at
    /// the rendered size so the remote PTY width always matches the surface.
    private var lastReportedSize: (cols: Int, rows: Int)?
    /// Set true by `disconnect()` / host deletion so we don't try to revive
    /// a session the user explicitly tore down.
    private var userInitiatedDisconnect = false
    /// True while the app is backgrounded (or transitioning there). Used to
    /// suppress error alerts and reconnect attempts that would otherwise
    /// surface when iOS suspends the process and tears down the WS — those
    /// failures are expected and handled by `resumeFromBackground`.
    private var isInBackground = false
    /// The live phase (`.tmuxReady`/`.shellReady`) captured when the session
    /// was suspended. If the transport survives the suspension (probed on
    /// resume), the phase is restored directly — no reconnect.
    private var phaseBeforeSuspend: SessionPhase?
    /// Consecutive state-poll commands that timed out with no response.
    /// A transport can be half-dead in ways no layer reports: the WS answers
    /// pings but the remote shell is gone, so tmux never replies while the
    /// screen sits frozen and "connected". Two straight timeouts (~25s) is
    /// the universal tripwire — it works over any transport.
    private var commandTimeoutStreak = 0

    private var layoutChangeDebounce: Task<Void, Never>?
    /// Retry for a raced `list-windows` parse (see `refreshWindows`).
    private var windowsRefreshRetry: Task<Void, Never>?
    private var statePollingTask: Task<Void, Never>?

    public init(host: Host, transport: TerminalTransport, environment: TerminalEnvironment) {
        self.host = host
        self.transport = transport
        self.environment = environment
        tmuxService.logHandler = { dlog($0) }
        setupCallbacks()
    }

    /// tmux control-mode parsing (line splitting, %output unescaping) runs
    /// here, off the main actor, so heavy TUI output cannot delay keyDown
    /// handling. Serial → preserves byte order.
    private nonisolated let tmuxParseQueue = DispatchQueue(label: "com.novashang.bento.tmux-parse", qos: .userInitiated)

    /// Notifications parsed off-main are queued here and drained on the main
    /// actor in one hop, preserving total order (a %layout-change must stay
    /// ordered against the %output repaint that follows it) while coalescing
    /// bursts that would otherwise each pay their own main-actor hop.
    private struct PendingTmuxNotifications {
        var queue: [TmuxNotification] = []
        var drainScheduled = false
    }
    private nonisolated let pendingTmuxNotifications = OSAllocatedUnfairLock(initialState: PendingTmuxNotifications())

    nonisolated private func enqueueTmuxNotification(_ notification: TmuxNotification) {
        let scheduleDrain = pendingTmuxNotifications.withLockUnchecked { state -> Bool in
            state.queue.append(notification)
            if state.drainScheduled { return false }
            state.drainScheduled = true
            return true
        }
        guard scheduleDrain else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainTmuxNotifications()
        }
    }

    private func drainTmuxNotifications() {
        let batch = pendingTmuxNotifications.withLockUnchecked { state -> [TmuxNotification] in
            state.drainScheduled = false
            let queue = state.queue
            state.queue.removeAll(keepingCapacity: true)
            return queue
        }

        // Merge consecutive .output runs for the same pane into a single
        // feed; everything else is handled in arrival order.
        var i = 0
        while i < batch.count {
            if case .output(let pane, let first) = batch[i] {
                var data = first
                var j = i + 1
                while j < batch.count, case .output(let nextPane, let more) = batch[j], nextPane == pane {
                    data.append(more)
                    j += 1
                }
                handleTmuxNotification(.output(pane: pane, data: data))
                i = j
            } else {
                handleTmuxNotification(batch[i])
                i += 1
            }
        }
    }

    private func setupCallbacks() {
        transport.onStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.connectionState = state
                if case .failed(let msg) = state {
                    self.handleUnexpectedFailure(message: msg)
                } else if case .connected = state {
                    // Successful (re)connect — clear the backoff counter.
                    self.reconnectAttempt = 0
                }
            }
        }

        transport.onDataReceived = { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                self.routeIncomingData(data)
            }
        }

        tmuxService.onNotification = { [weak self] notification in
            self?.enqueueTmuxNotification(notification)
        }

        tmuxService.sendToSSH = { [weak self] string in
            guard let data = string.data(using: .utf8) else { return }
            self?.transport.write(data)
        }
    }

    /// Route a chunk of bytes from SSH to the right consumer based on phase.
    private func routeIncomingData(_ data: Data) {
        // Capture mode (running a one-shot shell command silently).
        if var capture = shellCapture {
            capture.buffer.append(data)
            shellCapture = capture
            if let str = String(data: capture.buffer, encoding: .utf8),
               str.contains(capture.marker) {
                let result = str
                let cont = capture.continuation
                shellCapture = nil
                cont.resume(returning: result)
            }
            return
        }

        if usingTmux {
            // Parse off the main actor — under heavy TUI output the protocol
            // parse is the main thread's biggest contender with keyDown.
            let service = tmuxService
            tmuxParseQueue.async { service.feedData(data) }
            return
        }

        // Non-tmux: forward to single-pane terminal — but only after the user
        // has explicitly picked the no-tmux option. Until then we drop, so
        // shell prompts and our `tmux ls` output don't pollute the screen.
        if phase == .shellReady {
            // Reconcile predictions against the echo BEFORE it renders, so a
            // confirmed char's overlay is retired as the real byte paints over it.
            predictor.didReceive(data)
            appendRawHistory(data)
            onRawDataReceived?(data)
        }
    }

    private func appendRawHistory(_ data: Data) {
        rawHistory.append(data)
        let overflow = rawHistory.count - Self.maxRawHistoryBytes
        if overflow > 0 {
            rawHistory.removeSubrange(0..<overflow)
        }
    }

    // MARK: - Connect

    public func connect() async {
        userInitiatedDisconnect = false
        // NOTE: do NOT cancel `reconnectTask` here. `connect()` is called from
        // inside the reconnect loop (via `reattachExistingSession`); cancelling
        // would kill the loop mid-flight, so a single failed attempt would give
        // up instead of retrying with backoff. The loop owns `reconnectTask`;
        // user-initiated tear-downs cancel it in `disconnect()`.
        rawHistory.removeAll(keepingCapacity: true)
        guard let startedSize = await bringUpTransport() else { return }

        // Wait briefly for the shell prompt to settle.
        try? await Task.sleep(for: .milliseconds(500))

        // Re-assert the surface's real grid now that the channel is connected.
        // A resize that fired while the transport was still connecting gets
        // dropped (notably on the relay path), leaving the remote PTY a
        // different width than what we render — the shell drew its prompt at the
        // wrong width and only re-lays-out on SIGWINCH. Re-sending the size here
        // delivers that SIGWINCH so the prompt/TUI redraws at the rendered grid.
        if let s = lastReportedSize, s.cols != startedSize.cols || s.rows != startedSize.rows {
            dlog("post-connect resize to \(s.cols)x\(s.rows) (shell started at \(startedSize.cols)x\(startedSize.rows))")
            transport.resize(cols: s.cols, rows: s.rows)
        }

        // Optional: unlock keychain BEFORE listing sessions, so the next
        // command sees a stable shell.
        if host.unlockMacKeychain {
            await unlockMacKeychain()
        }

        // Move to choosing-session phase and load the session list.
        phase = .choosingSession
        await refreshTmuxSessions()
    }

    /// Bring the transport up and start the PTY at the rendered size. Shared
    /// by first connect (which continues into session discovery) and reattach
    /// (which skips straight to the tmux attach). Returns the size the shell
    /// was started at, or nil if the transport failed to connect.
    private func bringUpTransport() async -> (cols: Int, rows: Int)? {
        errorMessage = nil
        showError = false
        phase = .sshConnecting
        dlog("Connecting to \(self.host.hostname):\(self.host.port)")
        await transport.connect(host: host)

        guard case .connected = transport.state else {
            dlog("SSH connection failed: \(String(describing: self.transport.state))")
            return nil
        }

        // Start the shell at the surface's last reported grid if we have one
        // (it's authoritative); else fall back to the screen estimate. This
        // keeps the remote PTY width == the rendered grid even when the
        // surface's resize fired before the transport finished connecting.
        let screenSize = lastReportedSize ?? idealTerminalSize()
        dlog("startShell \(screenSize.cols)x\(screenSize.rows) (lastReported=\(String(describing: lastReportedSize)))")
        transport.startShell(cols: screenSize.cols, rows: screenSize.rows)
        return screenSize
    }

    /// Calculate ideal cols×rows to fill the screen. Used only for the initial
    /// SSH PTY size (before SwiftTerm has laid out) and the user-triggered
    /// "reset client size" button. Once SwiftTerm is rendering, its own
    /// `sizeChanged` callback drives all subsequent resizes — that path is
    /// authoritative and avoids any drift from this best-effort estimate.
    ///
    /// Uses the user-selected terminal font, not SF Mono, since custom fonts
    /// (Maple / JetBrains) have noticeably different advance widths. Does not
    /// round-up the cell width — Int() truncation already underestimates cols
    /// slightly; further ceil() would compound the loss.
    private func idealTerminalSize() -> (cols: Int, rows: Int) {
        environment.idealTerminalSize()
    }

    // MARK: - Session Picker

    /// Run `tmux ls` and parse the output into a list of session names.
    public func refreshTmuxSessions() async {
        sessionsLoading = true
        defer { sessionsLoading = false }

        // If we're already attached via tmux -CC, the SSH channel is owned by
        // the control-mode protocol and we can't run raw shell. Query the
        // server directly via the control command instead.
        if usingTmux {
            let response = await tmuxService.send(.listSessions)
            guard !response.isError else {
                dlog("list-sessions (control) error: \(response.output)")
                return
            }
            // Format: `$id:name` per line (set by Command.listSessions).
            availableTmuxSessions = response.output
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return String(parts[1])
                }
            dlog("Found tmux sessions (control): \(self.availableTmuxSessions)")
            return
        }

        // Bracket the tmux output with start + end markers. Each marker is
        // assembled from two halves so the PTY echo of the command line
        // (which renders both halves with a quote-and-space between them)
        // can never match the concatenated form. Only the runtime `printf`
        // produces a contiguous marker — so we can confidently slice the
        // output between markers to get a clean list of sessions, no matter
        // what OSC / CSI / syntax-highlight garbage the shell injected.
        let token = String(UUID().uuidString.prefix(8))
        let startA = "__SPK_S_\(token)_"
        let startB = "_GO__"
        let startMarker = startA + startB
        let endA = "__SPK_E_\(token)_"
        let endB = "_DONE__"
        let endMarker = endA + endB
        let cmd =
            "printf '\\n%s%s\\n' '\(startA)' '\(startB)';" +
            " tmux ls 2>/dev/null;" +
            " printf '%s%s\\n' '\(endA)' '\(endB)'\n"
        let output = await captureShellOutput(cmd: cmd, marker: endMarker, timeoutMs: 5000)
        availableTmuxSessions = TmuxParsers.parseTmuxLs(output, startMarker: startMarker, endMarker: endMarker)
        dlog("Found tmux sessions: \(self.availableTmuxSessions)")
    }

    /// Send a shell command and capture all output until `marker` is observed
    /// (or until timeout). Output is consumed silently and not forwarded to
    /// the terminal.
    private func captureShellOutput(cmd: String, marker: String, timeoutMs: Int) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            shellCapture = ShellCapture(buffer: Data(), marker: marker, continuation: continuation)
            transport.write(cmd)

            // Timeout: if marker doesn't appear, return whatever we have.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                guard let self else { return }
                await MainActor.run {
                    if let capture = self.shellCapture {
                        let str = String(data: capture.buffer, encoding: .utf8) ?? ""
                        self.shellCapture = nil
                        capture.continuation.resume(returning: str)
                    }
                }
            }
        }
    }

    // Parsers / ANSI stripping live in the SwiftTmux package now.

    /// Apply the user's session choice. Called from the session picker UI.
    public func applyTmuxChoice(_ choice: TmuxStartChoice) async {
        phase = .starting
        switch choice {
        case .noTmux:
            // Move into shell-only mode: subsequent SSH data flows to the
            // single-pane terminal. Send a `clear` so the screen starts fresh
            // (the previous `tmux ls` output that we silently captured won't
            // appear on screen, but the cursor state is well-defined).
            phase = .shellReady
            transport.write("clear\n")
        case .createOrAttach(let name):
            // Only force the tmux client viewport to the phone screen when
            // we're CREATING a brand-new session — i.e. the name wasn't in
            // the just-fetched `tmux ls` output. On attach we want to keep
            // the existing session's server-side geometry; the canvas can
            // overflow the phone viewport and the user pans/zooms to see.
            let isAttachToExisting = availableTmuxSessions.contains(name)
            await launchTmux(
                sessionName: name,
                groupWith: nil,
                resizeToScreen: !isAttachToExisting
            )
        case .shareWithDesktop(let target):
            await launchTmux(sessionName: "\(target)-mobile", groupWith: target, resizeToScreen: false)
        case .createAgent(let spec):
            // Build the session detached first, then attach via -CC. The
            // setup script uses `tmux new-session -d` + split-window so the
            // session exists on the server before `launchTmux` runs its
            // `tmux -CC new-session -A -s <name>` (the -A attaches instead
            // of creating-anew).
            dlog("Creating agent session \(spec.sessionName) (\(spec.layout.paneCount) panes)")
            transport.write(spec.setupScript)
            try? await Task.sleep(for: .seconds(1))
            await launchTmux(sessionName: spec.sessionName, groupWith: nil, resizeToScreen: false)
        }
    }

    private func launchTmux(sessionName: String, groupWith: String?, resizeToScreen: Bool) async {
        usingTmux = true
        activeTmuxSessionName = sessionName

        let launchCmd = tmuxService.launchCommand(sessionName: sessionName, groupWith: groupWith)
        dlog("Launching tmux: \(launchCmd.trimmingCharacters(in: .whitespacesAndNewlines))")
        transport.write(launchCmd)

        // Wait for the -CC greeting (its first %begin) instead of a fixed
        // sleep: commands sent before tmux attaches would be typed into the
        // plain shell. Faster than 1s when the shell is quick, tolerant when
        // it's slow (fresh login shell runs the full zshrc first).
        let sawGreeting = await tmuxService.awaitControlMode(timeout: .seconds(12))
        if !sawGreeting {
            dlog("tmux -CC greeting not seen within 12s — proceeding anyway")
        }

        // Only resize the tmux client viewport when we created a new
        // standalone session, since shrinking a shared session would also
        // shrink the desktop's view.
        if resizeToScreen {
            let screen = idealTerminalSize()
            dlog("Setting tmux client size to \(screen.cols)x\(screen.rows)")
            tmuxService.sendFireAndForget(.refreshClient(width: screen.cols, height: screen.rows))
            try? await Task.sleep(for: .milliseconds(300))
        }

        dlog("Querying tmux panes and windows...")
        await refreshPanes()
        await refreshWindows()
        dlog("tmux ready: \(self.paneViewModels.count) panes, \(self.windows.count) windows")

        isTmuxReady = true
        phase = .tmuxReady
        startStatePolling()
    }

    // MARK: - tmux Notifications

    private func handleTmuxNotification(_ notification: TmuxNotification) {
        switch notification {
        case .output(let pane, let data):
            if let paneVM = paneViewModels.first(where: { $0.paneID == pane }) {
                paneVM.feedData(data)
            }
            stateDetection.recordOutput(pane: pane, data: data)

        case .layoutChange(_, let layout):
            // Apply the new pane geometry SYNCHRONOUSLY from the layout string.
            // tmux delivers %layout-change BEFORE the program's post-SIGWINCH
            // repaint %output in this same ordered stream, so resizing the
            // surfaces now guarantees they are at the new size when that repaint
            // is fed to ghostty. The previous debounced (300ms) list-panes path
            // left surfaces at the OLD size while the program repainted at the
            // NEW width → the repaint wrapped into the stale grid and stayed
            // garbled until the next resize. The debounced refresh still runs for
            // the rest of the metadata (titles, commands, mouse flags, added /
            // removed panes, active / zoom state).
            applyLayoutGeometry(layout)
            layoutChangeDebounce?.cancel()
            layoutChangeDebounce = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await refreshPanes()
            }

        case .windowAdd:
            Task { await refreshWindows() }

        case .windowClose:
            Task {
                await refreshWindows()
                await refreshPanes()
            }

        case .windowRenamed(let winID, let name):
            if let idx = windows.firstIndex(where: { $0.id == winID }) {
                windows[idx].name = name
            }

        case .sessionChanged(_, let name):
            // The control client attached to a different session (e.g. via the
            // top-bar session switcher). Adopt the new name and re-sync windows
            // and panes — the new session has different pane IDs, so the surfaces
            // must be rebuilt from the fresh list.
            activeTmuxSessionName = name
            Task {
                await refreshWindows()
                await refreshPanes()
            }

        case .sessionRenamed(let name):
            activeTmuxSessionName = name

        case .paneModeChanged(let pane, _):
            if let paneVM = paneViewModels.first(where: { $0.paneID == pane }) {
                let state = stateDetection.detectState(pane: pane, currentCommand: paneVM.pane.currentCommand, title: paneVM.pane.title)
                paneVM.paneState = state
                stateVersion += 1
            }

        case .exit:
            usingTmux = false
            isTmuxReady = false
            phase = .ended
        }
    }

    // MARK: - Pane Management

    public func refreshPanes() async {
        // Session-wide (-s): one command feeds both models — `sessionPanes`
        // (all windows, for the structure/list layer) and `paneViewModels`
        // (current window only, the panes with live surfaces).
        let response = await tmuxService.send(.listPanes(sessionWide: true))
        guard !response.isError else {
            dlog("list-panes error: \(response.output)")
            if response.output.hasPrefix("timeout") { noteCommandTimeout() }
            return
        }
        commandTimeoutStreak = 0

        let allPanes = TmuxParsers.parsePaneList(response.output)
        // Current window's panes via each line's own window_active flag — no
        // dependence on separately-refreshed (possibly stale) window state.
        let panes = allPanes.filter(\.inActiveWindow)
        dlog("Parsed \(allPanes.count) panes (\(panes.count) in active window): \(panes.map { "\($0.id) \($0.width)x\($0.height) at \($0.x),\($0.y)" })")

        // A live tmux session always has at least one pane. An empty parse here
        // is never real state — under fast input the `list-panes` response gets
        // raced/interleaved with `%output` and `parsePaneList` drops every line
        // (it `compactMap`s unparseable lines to nothing). Applying that empty
        // result would wipe `paneViewModels`, tearing down EVERY ghostty surface
        // (black screen + broken responder chain → each keystroke beeps) until
        // the next refresh rebuilds them. Real session/window teardown arrives
        // via `.exit` / `.windowClose`, which change `phase` — so while we still
        // hold panes and the session is live, treat empty as a transient glitch:
        // skip the destructive update and re-fetch shortly.
        // (No isTmuxReady condition: during a REATTACH isTmuxReady is still
        // false while panes are populated — applying an empty parse there
        // would wipe the view-models the surfaces are bound to, which is
        // exactly the "input works, rendering dead" zombie.)
        // A clean response parses every non-empty line; a shortfall means the
        // body was interleaved with %output (see refreshWindows) — partial
        // results would silently drop panes, so treat them like empty.
        let paneLineCount = response.output.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if panes.isEmpty || allPanes.count != paneLineCount, !paneViewModels.isEmpty, usingTmux {
            log.warning("refreshPanes: ignored raced list-panes parse (\(allPanes.count, privacy: .public)/\(paneLineCount, privacy: .public) lines, have \(self.paneViewModels.count, privacy: .public) panes) — re-fetching")
            layoutChangeDebounce?.cancel()
            layoutChangeDebounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await refreshPanes()
            }
            return
        }
        sessionPanes = allPanes
        updatePaneViewModels(panes)
    }

    public func refreshWindows() async {
        let response = await tmuxService.send(.listWindows())
        guard !response.isError else { return }
        let parsed = TmuxParsers.parseWindowList(response.output)

        // Under heavy output (e.g. the repaint burst right after select-window
        // resizes the newly-current window) the command response can get
        // interleaved with `%output`, so lines drop or split and the parse
        // comes back partial/empty — same race as refreshPanes' empty-parse
        // guard. Applying a partial list here shrinks `windows`, which
        // e.g. hides the phone's window tab bar until something else happens
        // to refresh. A CLEAN response parses every non-empty line as a
        // window and is never empty on a live session — anything else is
        // corrupt: keep the current list and re-fetch shortly.
        let lineCount = response.output.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if usingTmux, !windows.isEmpty, parsed.count != lineCount || parsed.isEmpty {
            log.warning("refreshWindows: ignored corrupt list-windows parse (\(parsed.count, privacy: .public)/\(lineCount, privacy: .public) lines, have \(self.windows.count, privacy: .public)) — re-fetching")
            windowsRefreshRetry?.cancel()
            windowsRefreshRetry = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await refreshWindows()
            }
            return
        }
        windows = parsed
        activeWindowID = windows.first(where: { $0.isActive })?.id ?? activeWindowID
    }

    /// Apply pane geometry parsed from a `%layout-change` layout string to the
    /// existing panes, immediately, so their ghostty surfaces resize before the
    /// program's repaint output arrives. Updates only geometry (the layout string
    /// carries no command/title/mouse/active info) on panes we already have; new
    /// or removed panes are reconciled by the debounced `refreshPanes`.
    private func applyLayoutGeometry(_ layout: String) {
        let geom = TmuxParsers.parsePaneGeometry(layout)
        guard !geom.isEmpty else { return }
        var changed = false
        for g in geom {
            guard let vm = paneViewModels.first(where: { $0.paneID == g.id }) else { continue }
            var p = vm.pane
            guard p.width != g.width || p.height != g.height || p.x != g.x || p.y != g.y else { continue }
            p.width = g.width; p.height = g.height; p.x = g.x; p.y = g.y
            vm.updatePane(p)
            changed = true
        }
        // Resize surfaces SYNCHRONOUSLY now (not via the async $paneViewModels
        // publisher), so they are at the new size before the program's repaint
        // %output — the next notification on this main-actor stream — is fed to
        // ghostty. Each pane already exists (geometry-only change), so the host
        // just re-runs layoutCells; added / removed panes are handled by the
        // debounced refreshPanes.
        if changed { onGeometryApplied?() }
    }

    /// Synchronous hook invoked right after `%layout-change` geometry is applied,
    /// before the subsequent repaint output is processed. The view layer sets
    /// this to re-tile its surfaces. See `applyLayoutGeometry`.
    public var onGeometryApplied: (() -> Void)?

    private func updatePaneViewModels(_ panes: [Pane]) {
        var newViewModels: [PaneViewModel] = []
        var newPaneIDs: [TmuxPaneID] = []

        for pane in panes {
            if let existing = paneViewModels.first(where: { $0.paneID == pane.id }) {
                existing.updatePane(pane)
                existing.isActive = pane.isActive
                newViewModels.append(existing)
            } else {
                let vm = PaneViewModel(pane: pane, tmuxService: tmuxService)
                vm.isActive = pane.isActive
                newViewModels.append(vm)
                newPaneIDs.append(pane.id)
            }
        }

        paneViewModels = newViewModels

        if !newPaneIDs.isEmpty {
            Task {
                for paneVM in paneViewModels where newPaneIDs.contains(paneVM.paneID) {
                    let lines = paneVM.pane.height > 0 ? paneVM.pane.height : 50
                    // `escapes: true` keeps SGR color/style codes so a freshly
                    // shown pane (e.g. after a window switch) seeds the surface in
                    // full color instead of plain text that then flashes when the
                    // live %output repaints. Detection (recordOutput below) strips
                    // ANSI anyway, so the escapes are harmless there.
                    let resp = await tmuxService.send(.capturePane(id: paneVM.paneID, lines: lines, escapes: true))
                    if !resp.isError {
                        let text = resp.output
                        let termText = text.replacingOccurrences(of: "\n", with: "\r\n")
                        if let data = termText.data(using: .utf8) {
                            paneVM.feedData(data)
                        }
                        if let rawData = text.data(using: .utf8) {
                            stateDetection.recordOutput(pane: paneVM.paneID, data: rawData)
                        }
                    }
                }
                await updatePaneStates()
            }
        }

        if let active = panes.first(where: { $0.isActive }) {
            activePaneID = active.id
            // window_zoomed_flag is per-window; the zoomed pane is the active one.
            zoomedPaneID = active.isZoomed ? active.id : nil
        } else {
            zoomedPaneID = nil
        }
    }

    // MARK: - Actions

    public func splitPane(horizontal: Bool) {
        if let activePaneID {
            tmuxService.sendFireAndForget(.selectPane(id: activePaneID))
        }
        tmuxService.sendFireAndForget(.splitWindow(target: activePaneID, horizontal: horizontal))
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshPanes()
        }
    }

    public func selectPane(_ paneID: TmuxPaneID) {
        guard usingTmux else { return }
        tmuxService.sendFireAndForget(.selectPane(id: paneID))
        activePaneID = paneID
        for vm in paneViewModels {
            vm.isActive = (vm.paneID == paneID)
            // Focusing a pane = seeing it → clear the "done, unseen" badge.
            if vm.paneID == paneID, vm.agentFinishedUnseen {
                vm.agentFinishedUnseen = false
            }
        }
    }

    public func resizePaneBy(_ paneID: TmuxPaneID, direction: String, amount: Int) {
        tmuxService.sendFireAndForget(.resizePaneBy(id: paneID, direction: direction, amount: amount))
    }

    public func toggleZoom(_ paneID: TmuxPaneID) {
        tmuxService.sendFireAndForget(.zoomPane(id: paneID))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    public func closePane(_ paneID: TmuxPaneID) {
        tmuxService.sendFireAndForget(.killPane(id: paneID))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    /// Swap a pane with its previous/next neighbor (tmux `swap-pane -U/-D`,
    /// same as tmux's `{`/`}` bindings). The resulting %layout-change moves
    /// each surface to its pane's new geometry — content follows pane IDs, so
    /// no repaint is needed beyond tmux's own resize output.
    public func swapPane(_ paneID: TmuxPaneID, up: Bool) {
        guard usingTmux else { return }
        tmuxService.sendFireAndForget(up ? .swapPaneUp(id: paneID) : .swapPaneDown(id: paneID))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    /// Swap two specific panes (drag a pane's title bar onto another pane).
    public func swapPanes(_ source: TmuxPaneID, with destination: TmuxPaneID) {
        guard usingTmux, source != destination else { return }
        tmuxService.sendFireAndForget(.swapPanes(source: source, destination: destination))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    /// Force a pane's detection profile (pane menu → Change Profile); nil =
    /// auto-detect. Takes effect on the next detection tick.
    public func setPaneProfile(_ profileID: String?, for paneID: TmuxPaneID) {
        stateDetection.setProfileOverride(profileID, for: paneID)
    }

    public func paneProfile(for paneID: TmuxPaneID) -> String? {
        stateDetection.profileOverride(for: paneID)
    }

    /// Rename a pane (sets `pane_title`, shown in the pane title bar / List rows).
    public func renamePane(_ paneID: TmuxPaneID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tmuxService.sendFireAndForget(.setPaneTitle(id: paneID, title: trimmed))
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await refreshPanes()
        }
    }

    /// Switch the attached control client to another tmux session on the same
    /// host (PRD §3.6 session switcher). tmux replies with %session-changed,
    /// which re-syncs windows/panes; we also refresh defensively in case the
    /// notification is missed.
    public func switchSession(_ name: String) {
        guard usingTmux, name != activeTmuxSessionName else { return }
        tmuxService.sendFireAndForget(.switchClient(session: name))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshWindows()
            await refreshPanes()
        }
    }

    /// Rename the attached tmux session (the toolbar's "Rename Session…").
    public func renameSession(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usingTmux, !trimmed.isEmpty, trimmed != activeTmuxSessionName else { return }
        tmuxService.sendFireAndForget(.renameSession(name: trimmed))
        activeTmuxSessionName = trimmed   // optimistic; %session-renamed reconciles
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await refreshTmuxSessions()
        }
    }

    public func newWindow(name: String? = nil) {
        tmuxService.sendFireAndForget(.newWindow(name: name))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshWindows()
            await refreshPanes()
        }
    }

    /// Rename the active tmux window (the session menu's "Rename Window…").
    public func renameWindow(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usingTmux, !trimmed.isEmpty, let id = activeWindowID else { return }
        tmuxService.sendFireAndForget(.renameWindow(id: id, name: trimmed))
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await refreshWindows()
        }
    }

    /// Close the active tmux window. Closing the session's last window ends the
    /// session (tmux semantics).
    public func closeWindow() {
        guard usingTmux, let id = activeWindowID else { return }
        tmuxService.sendFireAndForget(.killWindow(id: id))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshWindows()
            await refreshPanes()
        }
    }

    public func selectWindow(_ windowID: TmuxWindowID) {
        tmuxService.sendFireAndForget(.selectWindow(id: windowID))
        // Reflect the switch immediately (the tab highlight shouldn't wait for
        // the refresh round-trip); refreshWindows below reconciles authoritatively.
        activeWindowID = windowID
        for i in windows.indices { windows[i].isActive = (windows[i].id == windowID) }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
            await refreshWindows()
        }
    }

    // MARK: - Direct Input (non-tmux fallback)

    public func sendData(_ data: Data) {
        if usingTmux, let activePaneID,
           let paneVM = paneViewModels.first(where: { $0.paneID == activePaneID }) {
            paneVM.sendInput(data)
        } else {
            predictor.willSend(data)   // draw the prediction; doesn't alter what's sent
            transport.write(data)
        }
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendData(data)
    }

    /// Unlock the remote Mac's login keychain using stored password
    private func unlockMacKeychain() async {
        guard let password = await environment.loadKeychainPassword("macKeychain:\(host.id.uuidString)") else {
            dlog("No keychain password stored")
            return
        }
        let cmd = "security unlock-keychain -p \(shellEscape(password)) ~/Library/Keychains/login.keychain-db\n"
        transport.write(cmd)
        dlog("Sent keychain unlock command")
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func resizeTerminal(cols: Int, rows: Int) {
        // Remember the surface's authoritative grid so a (re)connect can start
        // the shell at the SAME size. Without this, a resize that fires before
        // the transport finishes connecting is lost, and startShell falls back
        // to the ideal/default size — leaving the remote PTY a different width
        // than what's rendered (e.g. relay: PTY 80×24 vs surface 41 cols), so
        // the prompt/TUI wraps wrong.
        if cols > 0, rows > 0 { lastReportedSize = (cols, rows) }
        transport.resize(cols: cols, rows: rows)
    }

    /// Resize the tmux control-mode client viewport. Tmux propagates this to
    /// each visible pane (SIGWINCH on the remote shell). Used when the visible
    /// area changes for a single-pane / zoomed / focused session so the active
    /// pane fills exactly the area above the keyboard — same UX as non-tmux.
    public func resizeTmuxClient(cols: Int, rows: Int) {
        guard usingTmux else { return }
        tmuxService.sendFireAndForget(.refreshClient(width: cols, height: rows))
    }

    /// User-triggered: resize the tmux client to fit the current device
    /// viewport at the native cell size. Useful after attaching to a session
    /// that was sized for a different client (e.g. desktop).
    public func resetTmuxClientToDeviceSize() {
        guard usingTmux else { return }
        let (cols, rows) = idealTerminalSize()
        tmuxService.sendFireAndForget(.refreshClient(width: cols, height: rows))
    }

    public func killSession() {
        if let name = activeTmuxSessionName {
            tmuxService.sendFireAndForget(.killSession(name: name))
        }
        disconnect()
    }

    public func disconnect() {
        userInitiatedDisconnect = true
        isReconnecting = false
        reconnectTask?.cancel()
        reconnectTask = nil
        statePollingTask?.cancel()
        statePollingTask = nil
        transport.disconnect()
        // Fail any in-flight tmux commands and drop parser state so a later
        // fresh connect on this VM starts clean.
        let service = tmuxService
        tmuxParseQueue.async { service.reset() }
        let priorName = activeTmuxSessionName ?? ""
        usingTmux = false
        isTmuxReady = false
        phase = .ended
        paneViewModels = []
        rawHistory.removeAll(keepingCapacity: false)
        environment.onSessionUpdate(host.id, priorName, 0, "")
    }

    /// Called when the app enters background. SSH will die naturally when iOS
    /// suspends the process; we just cancel the polling loop and mark the
    /// phase. tmux on the server keeps the session alive — re-attach on resume.
    public func suspendForBackground() {
        isInBackground = true
        // Any in-flight reconnect must be cancelled — it will only burn the
        // backoff counter while the process is suspended, surfacing a bogus
        // "Lost connection" alert when the user unlocks.
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isReconnecting = false
        statePollingTask?.cancel()
        statePollingTask = nil
        // Suspend regardless of phase. If the WS already died mid-handshake
        // we still want resume to retry rather than show an alert.
        // Remember where we were: if the socket survives the suspension,
        // resume restores this phase directly instead of reconnecting.
        switch phase {
        case .tmuxReady, .shellReady:
            phaseBeforeSuspend = phase
            phase = .suspended
        case .starting, .sshConnecting, .choosingSession:
            phaseBeforeSuspend = nil
            phase = .suspended
        case .suspended, .ended:
            break
        }
    }

    /// Called when the app returns to foreground. Revive the session if the
    /// live connection is gone. We recover from any non-live state — not just
    /// `.suspended` — because a reconnect that failed *before* the user
    /// backgrounded can leave `phase` stuck at `.sshConnecting`/`.ended`, and a
    /// foreground is exactly when the user expects a retry.
    public func resumeFromBackground() async {
        isInBackground = false
        switch phase {
        case .tmuxReady, .shellReady, .starting, .choosingSession:
            // Already live, or a connect is already progressing — nothing to do.
            return
        case .suspended, .ended, .sshConnecting:
            break
        }
        // Fast path: the socket usually SURVIVES a background suspension (iOS
        // freezes the process; it does not close TCP). Probe it — if alive,
        // keep the connection: output that queued while frozen flushes through
        // on its own, nothing was torn down, resume is instant. Tearing down a
        // healthy connection here was the main source of "reconnects on every
        // unlock even though nothing was wrong".
        if phase == .suspended, let prior = phaseBeforeSuspend,
           case .connected = transport.state {
            if await transport.probeLiveness() {
                dlog("resume: connection survived suspension — restoring \(String(describing: prior)), no reconnect")
                phaseBeforeSuspend = nil
                phase = prior
                if prior == .tmuxReady {
                    startStatePolling()
                    // Catch up on anything that changed while frozen (layout,
                    // new/killed panes) — output already replays by itself.
                    Task {
                        await self.refreshPanes()
                        await self.refreshWindows()
                    }
                }
                return
            }
            dlog("resume: probe failed — socket died during suspension")
        }
        phaseBeforeSuspend = nil
        dlog("Resuming session for \(self.host.hostname) (\(String(describing: self.phase)) → reconnect)")
        scheduleReconnect()
    }

    /// Run a fresh SSH connect and re-attach to whatever tmux session was
    /// active (if any). Returns whether the session came back up. Used only by
    /// the auto-reconnect loop.
    ///
    /// We do NOT wipe `paneViewModels` here: that briefly empties the list and
    /// then refills it with the same IDs in one synchronous hop, which the host
    /// coalesces into "no change" and so never rebinds the surfaces — they stay
    /// wired to the discarded PaneViewModel instances while live `%output` lands
    /// in fresh, surface-less ones (history fills but nothing paints, the
    /// "looks dead after reconnect" bug). Keeping the list lets
    /// `updatePaneViewModels` reuse the existing instances by ID, so each
    /// surface's binding — and its replayed history — survives the reconnect.
    @discardableResult
    private func reattachExistingSession() async -> Bool {
        // NOTE: we do NOT call transport.disconnect() here. The relay transport
        // tears its previous client down synchronously inside connectRelay,
        // with that client's callbacks detached first — so a discarded client
        // can never deliver a stale `.failed` that would spuriously re-trigger
        // reconnect (the "constantly reconnecting" loop). Doing it via
        // disconnect()'s deferred Task instead raced the fresh client.
        usingTmux = false
        isTmuxReady = false
        // Stop the pollers FIRST. The reconnect path (unlike disconnect/
        // suspend) used to leave state polling running, so list-panes kept
        // firing into the half-built connection — typed into the raw shell
        // before tmux -CC starts, with each orphaned continuation queueing up
        // in front of the new session's real responses (off-by-N mismatch,
        // timeout storm, watchdog re-reconnect loop). launchTmux restarts
        // polling once the session is actually ready.
        statePollingTask?.cancel()
        statePollingTask = nil
        layoutChangeDebounce?.cancel()
        layoutChangeDebounce = nil
        // The dead connection's protocol state is garbage: a truncated
        // response block and orphaned continuations would swallow the new
        // stream's notifications / steal its responses (the "input works but
        // nothing renders" zombie). Reset ON the parse queue so it runs after
        // any stale feedData already enqueued there — the new connection's
        // bytes can only be enqueued later, so ordering is safe.
        let service = tmuxService
        tmuxParseQueue.async { service.reset() }

        guard await bringUpTransport() != nil else { return false }

        guard let name = activeTmuxSessionName else {
            // Raw-shell session: the fresh shell already streams to the
            // surface once the phase is live again.
            phase = .shellReady
            return true
        }
        // Skip session discovery entirely — we know the session name, and
        // `tmux -CC new-session -A` attaches-or-creates in one step.
        // resizeToScreen:false preserves the session's server-side geometry.
        await launchTmux(sessionName: name, groupWith: nil, resizeToScreen: false)
        if isTmuxReady {
            await reseedAllPanes()
        }
        return isTmuxReady
    }

    /// After a reattach, the reused PaneViewModels' surfaces still show the
    /// pre-suspend screen — tmux does not repaint static content for a new
    /// control client, so anything that changed while we were gone would be
    /// missing until the program next redraws. Re-seed every pane with a
    /// capture-pane snapshot (clear + home first, so the snapshot REPLACES the
    /// stale screen instead of appending below it).
    private func reseedAllPanes() async {
        for paneVM in paneViewModels {
            let lines = paneVM.pane.height > 0 ? paneVM.pane.height : 50
            let resp = await tmuxService.send(.capturePane(id: paneVM.paneID, lines: lines, escapes: true))
            guard !resp.isError else { continue }
            let termText = resp.output.replacingOccurrences(of: "\n", with: "\r\n")
            var data = Data("\u{1b}[2J\u{1b}[H".utf8)
            data.append(Data(termText.utf8))
            paneVM.feedData(data)
            if let raw = resp.output.data(using: .utf8) {
                stateDetection.recordOutput(pane: paneVM.paneID, data: raw)
            }
        }
        await updatePaneStates()
    }

    // MARK: - Auto-reconnect

    /// Decide what to do when the SSH transport reports `.failed` mid-session.
    /// User-initiated tear-downs and pre-handshake failures surface the error
    /// to the user as before; transient failures during an established
    /// session (Wi-Fi blip, half-open WS, CF DO recycle) schedule a quiet
    /// reconnect with backoff.
    private func handleUnexpectedFailure(message: String) {
        guard !userInitiatedDisconnect else { return }
        // A reconnect loop is already running and owns recovery — its own
        // attempts surface transient `.failed` states we must not treat as
        // fresh failures (they'd spawn a duplicate error alert).
        guard !isReconnecting else { return }
        // If the app is backgrounded (lock screen, app switcher) the WS is
        // expected to die. Absorb the failure silently and let
        // `resumeFromBackground` retry on unlock.
        if isInBackground || phase == .suspended {
            reconnectTask?.cancel()
            reconnectTask = nil
            phase = .suspended
            return
        }
        let recoverable: Bool
        switch phase {
        case .tmuxReady, .shellReady, .starting:
            recoverable = true
        case .sshConnecting, .choosingSession, .suspended, .ended:
            recoverable = false
        }
        guard recoverable else {
            errorMessage = message
            showError = true
            return
        }
        scheduleReconnect()
    }

    /// Start a reconnect loop. Idempotent: a no-op while one is already running,
    /// backgrounded, or after a user-initiated tear-down. Drives `isReconnecting`
    /// so the UI shows progress instead of a frozen pane.
    private func scheduleReconnect() {
        guard reconnectTask == nil, !userInitiatedDisconnect, !isInBackground else { return }
        reconnectAttempt = 0
        isReconnecting = true
        errorMessage = nil
        showError = false
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    /// Reconnect with exponential backoff until the session is back or the
    /// attempt budget is spent. On giving up it surfaces an actionable error
    /// (the alert offers Retry → `retry()`), never a silent dead state.
    private func runReconnectLoop() async {
        defer {
            isReconnecting = false
            reconnectTask = nil
        }
        while !Task.isCancelled {
            if userInitiatedDisconnect || isInBackground { return }
            reconnectAttempt += 1
            dlog("auto-reconnect attempt \(self.reconnectAttempt)")
            if await reattachExistingSession() {
                reconnectAttempt = 0
                return
            }
            if Task.isCancelled || userInitiatedDisconnect || isInBackground { return }
            // Fast backoff (1/2/4/8s) for the first attempts, then settle into a
            // steady 15s cadence FOREVER. The old behavior gave up after 5
            // attempts with a dead-end alert — but a relay/daemon blip (CF
            // Durable Objects recycle naturally) can outlast any fixed budget,
            // and the corpse screen it left was the "reconnecting 卡住" the
            // user actually experienced. Backgrounding still cancels the loop.
            let delaySec = reconnectAttempt >= 5 ? 15 : 1 << (reconnectAttempt - 1)
            dlog("reconnect failed; retrying in \(delaySec)s")
            try? await Task.sleep(for: .seconds(delaySec))
        }
    }

    /// Two consecutive poll commands got no response: the session is dead in
    /// a way no transport layer reported. Force the reconnect path — it tears
    /// the half-dead connection down and attaches a fresh shell.
    private func noteCommandTimeout() {
        commandTimeoutStreak += 1
        guard commandTimeoutStreak >= 2 else { return }
        commandTimeoutStreak = 0
        guard phase == .tmuxReady, !isReconnecting, !isInBackground, !userInitiatedDisconnect else { return }
        dlog("tmux stopped answering (2 consecutive command timeouts) — forcing reconnect")
        scheduleReconnect()
    }

    /// User-driven retry from the connection-error alert: clear the give-up
    /// state and start a fresh reconnect loop.
    public func retry() {
        guard !isReconnecting else { return }
        userInitiatedDisconnect = false
        scheduleReconnect()
    }

    // MARK: - State Detection

    private func startStatePolling() {
        // Idempotent: never stack a second poller — each leaked poller adds
        // another list-panes every 2s and floods the response queue.
        statePollingTask?.cancel()
        statePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { break }
                // Re-query panes so per-pane mouse-mode flags (mouse_any/sgr) stay
                // current — tmux -CC never streams the program's mouse-enable, so
                // polling list-panes is how the GUI learns to forward the mouse.
                await self.refreshPanes()
                await self.updatePaneStates()
            }
        }
    }

    private func updatePaneStates() async {
        var changed = false
        var awaitingCount = 0
        var sawNewAwaiting = false
        var latestPrompt = ""
        var agentWorking = 0
        var agentWaiting = 0
        var agentDoneUnseen = 0

        for paneVM in paneViewModels {
            let cmd = paneVM.pane.currentCommand
            let title = paneVM.pane.title ?? ""
            let current = paneVM.paneState
            var isAgent = true
            let newState: PaneState

            // Recognized coding agents go through the region/priority rule engine
            // (title is the cheap pass; a spinner resolves to .working with no
            // tmux round-trip — otherwise capture the live screen and re-classify).
            // Everything else stays on the legacy activity/profile path.
            switch stateDetection.classifyAgent(command: cmd, title: title, snapshot: nil,
                                                pane: paneVM.paneID, current: current) {
            case .notAgent:
                isAgent = false
                newState = stateDetection.detectState(pane: paneVM.paneID,
                                                      currentCommand: cmd, title: title)
            case .state(let s):
                newState = s
            case .needsSnapshot:
                let snap = await captureSnapshot(paneVM.paneID)
                if case .state(let s) = stateDetection.classifyAgent(
                    command: cmd, title: title, snapshot: snap,
                    pane: paneVM.paneID, current: current) {
                    newState = s
                } else {
                    newState = current
                }
            }

            if paneVM.paneState != newState {
                // Transition INTO awaiting/blocked — fire haptic + snippet.
                if case .awaitingInput = newState {
                    sawNewAwaiting = true
                    let snippet = stateDetection.recentText(for: paneVM.paneID, lines: 3)
                    if !snippet.isEmpty { latestPrompt = snippet }
                }
                paneVM.paneState = newState
                changed = true
            }

            if updateSeen(paneVM, from: current, to: newState, isAgent: isAgent) {
                changed = true
            }

            if case .awaitingInput = paneVM.paneState {
                awaitingCount += 1
            }

            // Tally agent activity for the toolbar's center summary.
            if isAgent {
                if paneVM.agentFinishedUnseen { agentDoneUnseen += 1 }
                switch paneVM.paneState {
                case .working:       agentWorking += 1
                case .awaitingInput: agentWaiting += 1
                case .idle:          break
                }
            }
        }
        if changed {
            stateVersion += 1
        }
        if agentsWorking != agentWorking { agentsWorking = agentWorking }
        if agentsWaiting != agentWaiting { agentsWaiting = agentWaiting }
        if agentsDoneUnseen != agentDoneUnseen { agentsDoneUnseen = agentDoneUnseen }
        if sawNewAwaiting {
            environment.onAwaitingTriggered()
        }
        // Fan into SessionManager so the aggregate Live Activity recomputes
        // across all live sessions.
        environment.onSessionUpdate(host.id, activeTmuxSessionName ?? "", awaitingCount, latestPrompt)
    }

    /// Fetch a pane's live visible screen (no scrollback, plain text) for the
    /// agent rule engine. nil on error.
    private func captureSnapshot(_ id: TmuxPaneID) async -> String? {
        let resp = await tmuxService.send(.capturePane(id: id, lines: nil))
        return resp.isError ? nil : resp.output
    }

    /// Maintain the "done, unseen" flag. An agent pane that transitions into
    /// .idle while unfocused becomes done(unseen); focusing it or leaving idle
    /// clears it. Returns true if the flag changed (so the UI repaints).
    @discardableResult
    private func updateSeen(_ paneVM: PaneViewModel, from current: PaneState,
                            to newState: PaneState, isAgent: Bool) -> Bool {
        let want: Bool
        if isAgent, case .idle = newState {
            if paneVM.isActive {
                want = false                       // you're looking at it → seen
            } else if Self.isIdle(current) {
                want = paneVM.agentFinishedUnseen  // already idle → keep memory
            } else {
                want = true                        // just finished, unfocused → done
            }
        } else {
            want = false
        }
        guard paneVM.agentFinishedUnseen != want else { return false }
        paneVM.agentFinishedUnseen = want
        return true
    }

    private static func isIdle(_ s: PaneState) -> Bool {
        if case .idle = s { return true }
        return false
    }
}
