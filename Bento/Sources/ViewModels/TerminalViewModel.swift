import Foundation
import SwiftUI
import os
import SwiftTmux

private let log = Logger(subsystem: "com.novashang.bento", category: "TerminalVM")

/// User's choice for how to start a session on the host.
enum TmuxStartChoice: Hashable {
    /// Don't use tmux — plain shell.
    case noTmux
    /// Create or attach to a session by name (no grouping).
    case createOrAttach(name: String)
    /// Create a grouped session that mirrors `target` (shared with desktop).
    case shareWithDesktop(target: String)
}

/// High-level session phase. Distinct from low-level SSH state.
enum SessionPhase: Equatable {
    case sshConnecting       // SSH handshake in progress
    case choosingSession     // SSH up; user picking tmux mode
    case starting            // applying choice (e.g. running tmux -CC)
    case shellReady          // non-tmux: plain shell live
    case tmuxReady           // tmux multiplexer live
    case suspended           // app backgrounded; SSH may be dead, tmux still alive on server
    case ended
}

@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var connectionState: SSHConnectionState = .disconnected
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var paneViewModels: [PaneViewModel] = []
    @Published var activePaneID: TmuxPaneID?
    @Published var windows: [TmuxWindow] = []
    @Published var isTmuxReady = false

    /// Where we are in the session lifecycle.
    @Published var phase: SessionPhase = .sshConnecting

    /// Sessions discovered via `tmux ls` after SSH is up.
    @Published var availableTmuxSessions: [String] = []
    @Published var sessionsLoading: Bool = false

    /// Incremented on each state poll cycle to trigger SwiftUI re-render
    @Published var stateVersion: Int = 0

    let host: Host
    let sshService = SSHService()
    let tmuxService = TmuxControlMode()
    let stateDetection = StateDetectionService()

    /// For non-tmux fallback: direct terminal data callback
    nonisolated(unsafe) var onRawDataReceived: (@Sendable (Data) -> Void)?

    /// Whether we're using tmux control mode
    nonisolated(unsafe) private(set) var usingTmux = false

    /// Active tmux session name (used for kill-session etc).
    @Published private(set) var activeTmuxSessionName: String?

    /// Shell-output capture state (for `tmux ls` and similar commands run in
    /// raw shell mode before we hand off to either the terminal or tmux -CC).
    private struct ShellCapture {
        var buffer: Data = Data()
        var marker: String
        var continuation: CheckedContinuation<String, Never>
    }
    private var shellCapture: ShellCapture?

    /// Pending auto-reconnect attempt; nil when not waiting. Used so we don't
    /// spawn a nested retry while one is already scheduled.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// Set by `disconnect()` so we don't try to revive a session the user
    /// explicitly tore down.
    private var userInitiatedDisconnect = false
    private static let maxReconnectAttempts = 5

    private var layoutChangeDebounce: Task<Void, Never>?
    private var statePollingTask: Task<Void, Never>?

    init(host: Host) {
        self.host = host
        tmuxService.logHandler = { dlog($0) }
        setupCallbacks()
    }

    /// Handle voice input result — inject text into active pane
    func handleVoiceResult(_ result: VoiceInputController.VoiceInputResult) {
        switch result.direction {
        case .none:
            sendString(result.text)
        case .up:
            sendString(result.text)
            if let data = "\r".data(using: .utf8) {
                sendData(data)
            }
        case .left, .right:
            // LLM-assisted: convert NL to a shell command using recent context.
            Task {
                let context = recentPaneContext()
                let command = await LLMService.shared.convertToShellCommand(
                    transcript: result.text,
                    context: context
                )
                if !command.isEmpty {
                    sendString(command)
                    if result.direction == .right {
                        // Right swipe: send Enter too (run immediately).
                        if let data = "\r".data(using: .utf8) { sendData(data) }
                    }
                }
            }
        case .down:
            break
        }
    }

    /// Recent terminal text used as LLM context.
    private func recentPaneContext() -> String {
        if let activePaneID {
            return stateDetection.recentText(for: activePaneID, lines: 30)
        }
        return ""
    }

    private func setupCallbacks() {
        sshService.onStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.connectionState = state
                if case .failed(let msg) = state {
                    self.handleUnexpectedFailure(message: msg)
                } else if case .connected = state {
                    self.reconnectAttempt = 0
                }
            }
        }

        sshService.onDataReceived = { [weak self] data in
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
            self?.sshService.write(data)
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
            onRawDataReceived?(data)
        }
    }

    // MARK: - Connect

    func connect() async {
        userInitiatedDisconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        errorMessage = nil
        showError = false
        phase = .sshConnecting
        dlog("Connecting to \(self.host.hostname):\(self.host.port)")
        await sshService.connect(host: host)

        guard case .connected = sshService.state else {
            dlog("SSH connection failed: \(String(describing: self.sshService.state))")
            return
        }
        dlog("SSH connected, starting shell")

        // Calculate terminal size to fill the device screen.
        let screenSize = idealTerminalSize()
        sshService.startShell(cols: screenSize.cols, rows: screenSize.rows)

        // Wait briefly for the shell prompt to settle.
        try? await Task.sleep(for: .milliseconds(500))

        // Optional: unlock keychain BEFORE listing sessions, so the next
        // command sees a stable shell.
        if host.unlockMacKeychain {
            await unlockMacKeychain()
        }

        // Move to choosing-session phase and load the session list.
        phase = .choosingSession
        await refreshTmuxSessions()
    }

    /// Calculate ideal cols×rows to fill the screen
    private func idealTerminalSize() -> (cols: Int, rows: Int) {
        let screen = UIScreen.main.bounds
        let font = UIFont.monospacedSystemFont(ofSize: STTheme.terminalFontSize, weight: .regular)
        let sample = NSString(string: "M")
        let cellSize = sample.size(withAttributes: [.font: font])

        let topBarHeight: CGFloat = 50
        let safeAreaTop: CGFloat = 60 // approximate
        let availableWidth = screen.width
        let availableHeight = screen.height - topBarHeight - safeAreaTop

        let cols = max(Int(availableWidth / cellSize.width), 40)
        let rows = max(Int(availableHeight / cellSize.height), 20)
        return (cols, rows)
    }

    // MARK: - Session Picker

    /// Run `tmux ls` and parse the output into a list of session names.
    func refreshTmuxSessions() async {
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
            sshService.write(cmd)

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
    func applyTmuxChoice(_ choice: TmuxStartChoice) async {
        phase = .starting
        switch choice {
        case .noTmux:
            // Move into shell-only mode: subsequent SSH data flows to the
            // single-pane terminal. Send a `clear` so the screen starts fresh
            // (the previous `tmux ls` output that we silently captured won't
            // appear on screen, but the cursor state is well-defined).
            phase = .shellReady
            sshService.write("clear\n")
        case .createOrAttach(let name):
            await launchTmux(sessionName: name, groupWith: nil, resizeToScreen: true)
        case .shareWithDesktop(let target):
            await launchTmux(sessionName: "\(target)-mobile", groupWith: target, resizeToScreen: false)
        }
    }

    private func launchTmux(sessionName: String, groupWith: String?, resizeToScreen: Bool) async {
        usingTmux = true
        activeTmuxSessionName = sessionName

        let launchCmd = tmuxService.launchCommand(sessionName: sessionName, groupWith: groupWith)
        dlog("Launching tmux: \(launchCmd.trimmingCharacters(in: .whitespacesAndNewlines))")
        sshService.write(launchCmd)

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

    func refreshPanes() async {
        let response = await tmuxService.send(.listPanes())
        guard !response.isError else {
            dlog("list-panes error: \(response.output)")
            return
        }

        let panes = TmuxParsers.parsePaneList(response.output)
        dlog("Parsed \(panes.count) panes: \(panes.map { "\($0.id) \($0.width)x\($0.height) at \($0.x),\($0.y)" })")
        updatePaneViewModels(panes)
    }

    func refreshWindows() async {
        let response = await tmuxService.send(.listWindows())
        guard !response.isError else { return }
        windows = TmuxParsers.parseWindowList(response.output)
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
        }
    }

    // MARK: - Actions

    func splitPane(horizontal: Bool) {
        if let activePaneID {
            tmuxService.sendFireAndForget(.selectPane(id: activePaneID))
        }
        tmuxService.sendFireAndForget(.splitWindow(target: activePaneID, horizontal: horizontal))
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshPanes()
        }
    }

    func selectPane(_ paneID: TmuxPaneID) {
        guard usingTmux else { return }
        tmuxService.sendFireAndForget(.selectPane(id: paneID))
        activePaneID = paneID
        for vm in paneViewModels {
            vm.isActive = (vm.paneID == paneID)
        }
    }

    func resizePaneBy(_ paneID: TmuxPaneID, direction: String, amount: Int) {
        tmuxService.sendFireAndForget(.resizePaneBy(id: paneID, direction: direction, amount: amount))
    }

    func toggleZoom(_ paneID: TmuxPaneID) {
        tmuxService.sendFireAndForget(.zoomPane(id: paneID))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    func closePane(_ paneID: TmuxPaneID) {
        tmuxService.sendFireAndForget(.killPane(id: paneID))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    func newWindow(name: String? = nil) {
        tmuxService.sendFireAndForget(.newWindow(name: name))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshWindows()
            await refreshPanes()
        }
    }

    func selectWindow(_ windowID: TmuxWindowID) {
        tmuxService.sendFireAndForget(.selectWindow(id: windowID))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    // MARK: - Direct Input (non-tmux fallback)

    func sendData(_ data: Data) {
        if usingTmux, let activePaneID,
           let paneVM = paneViewModels.first(where: { $0.paneID == activePaneID }) {
            paneVM.sendInput(data)
        } else {
            sshService.write(data)
        }
    }

    func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendData(data)
    }

    /// Unlock the remote Mac's login keychain using stored password
    private func unlockMacKeychain() async {
        do {
            let password = try KeychainService.shared.loadPassword(for: "macKeychain:\(host.id.uuidString)")
            let cmd = "security unlock-keychain -p \(shellEscape(password)) ~/Library/Keychains/login.keychain-db\n"
            sshService.write(cmd)
            dlog("Sent keychain unlock command")
            try? await Task.sleep(for: .milliseconds(300))
        } catch {
            dlog("No keychain password stored: \(error)")
        }
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func resizeTerminal(cols: Int, rows: Int) {
        sshService.resize(cols: cols, rows: rows)
    }

    func killSession() {
        if let name = activeTmuxSessionName {
            tmuxService.sendFireAndForget(.killSession(name: name))
        }
        disconnect()
    }

    func disconnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        statePollingTask?.cancel()
        statePollingTask = nil
        sshService.disconnect()
        let priorName = activeTmuxSessionName ?? ""
        usingTmux = false
        isTmuxReady = false
        phase = .ended
        paneViewModels = []
        SessionManager.shared.sessionDidUpdate(
            hostID: host.id,
            tmuxSessionName: priorName,
            awaitingPanes: 0,
            latestPrompt: ""
        )
    }

    /// Called when the app enters background. SSH will die naturally when iOS
    /// suspends the process; we just cancel the polling loop and mark the
    /// phase. tmux on the server keeps the session alive — re-attach on resume.
    func suspendForBackground() {
        guard phase == .tmuxReady || phase == .shellReady else { return }
        statePollingTask?.cancel()
        statePollingTask = nil
        phase = .suspended
    }

    /// Called when the app returns to foreground. If we were suspended, attempt
    /// SSH re-connect and re-attach to the same tmux session by name.
    func resumeFromBackground() async {
        guard phase == .suspended else { return }
        dlog("Resuming session for \(self.host.hostname) (suspended → reconnect)")
        await reattachExistingSession()
    }

    /// Run a fresh SSH connect and re-attach to whatever tmux session was
    /// active. Shared by `resumeFromBackground` (foreground return) and the
    /// auto-reconnect retry loop (mid-session WS death).
    private func reattachExistingSession() async {
        usingTmux = false
        isTmuxReady = false
        paneViewModels = []
        await connect()
        guard case .connected = sshService.state else { return }
        if let name = activeTmuxSessionName {
            await applyTmuxChoice(.createOrAttach(name: name))
        }
    }

    // MARK: - Auto-reconnect

    /// Decide what to do when the SSH transport reports `.failed` mid-session.
    /// Pre-handshake or user-initiated failures surface the error like
    /// before; transient failures during an established session (Wi-Fi blip,
    /// half-open WS, CF DO recycle) schedule a quiet reconnect with backoff.
    private func handleUnexpectedFailure(message: String) {
        guard !userInitiatedDisconnect else { return }
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
        // 1s, 2s, 4s, 8s, 16s — capped.
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
            HapticService.shared.awaitingTriggered()
        }
        // Fan into SessionManager so the aggregate Live Activity recomputes
        // across all live sessions.
        SessionManager.shared.sessionDidUpdate(
            hostID: host.id,
            tmuxSessionName: activeTmuxSessionName ?? "",
            awaitingPanes: awaitingCount,
            latestPrompt: latestPrompt
        )
    }
}
