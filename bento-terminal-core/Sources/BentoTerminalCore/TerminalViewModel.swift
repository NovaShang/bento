import Foundation
import SwiftUI
import os
import SwiftTmux

private let log = Logger(subsystem: "com.novashang.bento", category: "TerminalVM")

/// Package-local debug log (the app's global `dlog` lives in the iOS target).
func dlog(_ s: String) { log.debug("\(s, privacy: .public)") }

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
    @Published public var paneViewModels: [PaneViewModel] = []
    @Published public var activePaneID: TmuxPaneID?
    /// The currently zoomed pane (tmux `window_zoomed_flag`), or nil. When set,
    /// the tiled host shows only this pane filling the window.
    @Published public var zoomedPaneID: TmuxPaneID?
    @Published public var windows: [TmuxWindow] = []
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
    private static let maxReconnectAttempts = 5

    private var layoutChangeDebounce: Task<Void, Never>?
    private var statePollingTask: Task<Void, Never>?

    public init(host: Host, transport: TerminalTransport, environment: TerminalEnvironment) {
        self.host = host
        self.transport = transport
        self.environment = environment
        tmuxService.logHandler = { dlog($0) }
        setupCallbacks()
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
            Task { @MainActor in
                self?.handleTmuxNotification(notification)
            }
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
            tmuxService.feedData(data)
            return
        }

        // Non-tmux: forward to single-pane terminal — but only after the user
        // has explicitly picked the no-tmux option. Until then we drop, so
        // shell prompts and our `tmux ls` output don't pollute the screen.
        if phase == .shellReady {
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
        reconnectTask?.cancel()
        reconnectTask = nil
        errorMessage = nil
        showError = false
        rawHistory.removeAll(keepingCapacity: true)
        phase = .sshConnecting
        dlog("Connecting to \(self.host.hostname):\(self.host.port)")
        await transport.connect(host: host)

        guard case .connected = transport.state else {
            dlog("SSH connection failed: \(String(describing: self.transport.state))")
            return
        }
        dlog("SSH connected, starting shell")

        // Start the shell at the surface's last reported grid if we have one
        // (it's authoritative); else fall back to the screen estimate. This
        // keeps the remote PTY width == the rendered grid even when the
        // surface's resize fired before the transport finished connecting.
        let screenSize = lastReportedSize ?? idealTerminalSize()
        dlog("startShell \(screenSize.cols)x\(screenSize.rows) (lastReported=\(String(describing: lastReportedSize)))")
        transport.startShell(cols: screenSize.cols, rows: screenSize.rows)

        // Wait briefly for the shell prompt to settle.
        try? await Task.sleep(for: .milliseconds(500))

        // Re-assert the surface's real grid now that the channel is connected.
        // A resize that fired while the transport was still connecting gets
        // dropped (notably on the relay path), leaving the remote PTY a
        // different width than what we render — the shell drew its prompt at the
        // wrong width and only re-lays-out on SIGWINCH. Re-sending the size here
        // delivers that SIGWINCH so the prompt/TUI redraws at the rendered grid.
        if let s = lastReportedSize, s.cols != screenSize.cols || s.rows != screenSize.rows {
            dlog("post-connect resize to \(s.cols)x\(s.rows) (shell started at \(screenSize.cols)x\(screenSize.rows))")
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

        try? await Task.sleep(for: .seconds(1))

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

        case .layoutChange:
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

        case .sessionChanged, .sessionRenamed:
            break

        case .paneModeChanged(let pane, _):
            if let paneVM = paneViewModels.first(where: { $0.paneID == pane }) {
                let state = stateDetection.detectState(pane: pane, currentCommand: paneVM.pane.currentCommand)
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
        let response = await tmuxService.send(.listPanes())
        guard !response.isError else {
            dlog("list-panes error: \(response.output)")
            return
        }

        let panes = TmuxParsers.parsePaneList(response.output)
        dlog("Parsed \(panes.count) panes: \(panes.map { "\($0.id) \($0.width)x\($0.height) at \($0.x),\($0.y)" })")
        updatePaneViewModels(panes)
    }

    public func refreshWindows() async {
        let response = await tmuxService.send(.listWindows())
        guard !response.isError else { return }
        windows = TmuxParsers.parseWindowList(response.output)
        activeWindowID = windows.first(where: { $0.isActive })?.id ?? activeWindowID
    }

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
                    let resp = await tmuxService.send(.capturePane(id: paneVM.paneID, lines: lines))
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
                updatePaneStates()
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

    public func newWindow(name: String? = nil) {
        tmuxService.sendFireAndForget(.newWindow(name: name))
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
        reconnectTask?.cancel()
        reconnectTask = nil
        statePollingTask?.cancel()
        statePollingTask = nil
        transport.disconnect()
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
        statePollingTask?.cancel()
        statePollingTask = nil
        // Suspend regardless of phase. If the WS already died mid-handshake
        // we still want resume to retry rather than show an alert.
        switch phase {
        case .tmuxReady, .shellReady, .starting, .sshConnecting, .choosingSession:
            phase = .suspended
        case .suspended, .ended:
            break
        }
    }

    /// Called when the app returns to foreground. If we were suspended, attempt
    /// SSH re-connect and re-attach to the same tmux session by name.
    public func resumeFromBackground() async {
        isInBackground = false
        guard phase == .suspended else { return }
        dlog("Resuming session for \(self.host.hostname) (suspended → reconnect)")
        await reattachExistingSession()
    }

    /// Run a fresh SSH connect and re-attach to whatever tmux session was
    /// active (if any). Used by both `resumeFromBackground` and the auto-
    /// reconnect retry loop. Caller decides whether to gate on a phase.
    private func reattachExistingSession() async {
        usingTmux = false
        isTmuxReady = false
        paneViewModels = []
        await connect()
        guard case .connected = transport.state else { return }
        if let name = activeTmuxSessionName {
            await applyTmuxChoice(.createOrAttach(name: name))
        }
    }

    // MARK: - Auto-reconnect

    /// Decide what to do when the SSH transport reports `.failed` mid-session.
    /// User-initiated tear-downs and pre-handshake failures surface the error
    /// to the user as before; transient failures during an established
    /// session (Wi-Fi blip, half-open WS, CF DO recycle) schedule a quiet
    /// reconnect with backoff.
    private func handleUnexpectedFailure(message: String) {
        guard !userInitiatedDisconnect else { return }
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

    private func scheduleReconnect() {
        if reconnectTask != nil { return }
        reconnectAttempt += 1
        if reconnectAttempt > Self.maxReconnectAttempts {
            errorMessage = "Lost connection. Try reopening the session."
            showError = true
            phase = .ended
            return
        }
        // 1s, 2s, 4s, 8s, 16s — capped at 16s.
        let delaySec = min(16, 1 << (reconnectAttempt - 1))
        dlog("auto-reconnect attempt \(self.reconnectAttempt) in \(delaySec)s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySec))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            if self.userInitiatedDisconnect { return }
            await self.reattachExistingSession()
        }
    }

    // MARK: - State Detection

    private func startStatePolling() {
        statePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { break }
                // Re-query panes so per-pane mouse-mode flags (mouse_any/sgr) stay
                // current — tmux -CC never streams the program's mouse-enable, so
                // polling list-panes is how the GUI learns to forward the mouse.
                await self.refreshPanes()
                self.updatePaneStates()
            }
        }
    }

    private func updatePaneStates() {
        var changed = false
        var awaitingCount = 0
        var sawNewAwaiting = false
        var latestPrompt = ""

        for paneVM in paneViewModels {
            let newState = stateDetection.detectState(
                pane: paneVM.paneID,
                currentCommand: paneVM.pane.currentCommand
            )
            if paneVM.paneState != newState {
                // Detect transition INTO awaiting state — fire haptic + capture
                // a snippet for the Live Activity.
                if case .awaitingInput = newState, paneVM.paneState != newState {
                    sawNewAwaiting = true
                    let snippet = stateDetection.recentText(for: paneVM.paneID, lines: 3)
                    if !snippet.isEmpty { latestPrompt = snippet }
                }
                paneVM.paneState = newState
                changed = true
            }
            if case .awaitingInput = paneVM.paneState {
                awaitingCount += 1
            }
        }
        if changed {
            stateVersion += 1
        }
        if sawNewAwaiting {
            environment.onAwaitingTriggered()
        }
        // Fan into SessionManager so the aggregate Live Activity recomputes
        // across all live sessions.
        environment.onSessionUpdate(host.id, activeTmuxSessionName ?? "", awaitingCount, latestPrompt)
    }
}
