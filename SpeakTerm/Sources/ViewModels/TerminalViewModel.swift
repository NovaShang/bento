import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.speakterm", category: "TerminalVM")

@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var connectionState: SSHConnectionState = .disconnected
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var paneViewModels: [PaneViewModel] = []
    @Published var activePaneID: TmuxPaneID?
    @Published var windows: [TmuxWindow] = []
    @Published var isTmuxReady = false
    @Published var inputMode: InputMode = .voice

    /// Incremented on each state poll cycle to trigger SwiftUI re-render
    @Published var stateVersion: Int = 0

    let host: Host
    let sshService = SSHService()
    let tmuxService = TmuxControlModeService()
    let stateDetection = StateDetectionService()

    /// For non-tmux fallback: direct terminal data callback
    nonisolated(unsafe) var onRawDataReceived: (@Sendable (Data) -> Void)?

    /// Whether we're using tmux control mode
    nonisolated(unsafe) private(set) var usingTmux = false

    private var layoutChangeDebounce: Task<Void, Never>?
    private var statePollingTask: Task<Void, Never>?

    init(host: Host) {
        self.host = host
        self.inputMode = InputModeStore.shared.mode(for: host.id)
        setupCallbacks()
    }

    func toggleInputMode() {
        inputMode = (inputMode == .voice) ? .keyboard : .voice
        InputModeStore.shared.setMode(inputMode, for: host.id)
    }

    /// Handle voice input result — inject text into active pane
    func handleVoiceResult(_ result: VoiceInputController.VoiceInputResult) {
        switch result.direction {
        case .none:
            // Just inject text (no newline)
            sendString(result.text)
        case .up:
            // Inject text + Enter (send command)
            sendString(result.text)
            if let data = "\r".data(using: .utf8) {
                sendData(data)
            }
        case .left, .right:
            // LLM conversion stub — for now just inject the text
            // Phase 6 will add real LLM integration
            sendString(result.text)
        case .down:
            // Cancel — already handled in VoiceInputController
            break
        }
    }

    private func setupCallbacks() {
        sshService.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.connectionState = state
                if case .failed(let msg) = state {
                    self?.errorMessage = msg
                    self?.showError = true
                }
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

    // MARK: - Connect

    func connect() async {
        errorMessage = nil
        showError = false
        dlog("Connecting to \(self.host.hostname):\(self.host.port)")
        await sshService.connect(host: host)

        guard case .connected = sshService.state else {
            dlog("SSH connection failed: \(String(describing: self.sshService.state))")
            return
        }
        dlog("SSH connected, starting shell")

        // Start a shell first, then launch tmux inside it
        sshService.onDataReceived = { [weak self] data in
            guard let self else { return }
            if self.usingTmux {
                self.tmuxService.feedData(data)
            } else {
                self.onRawDataReceived?(data)
            }
        }

        // Calculate terminal size to fill the device screen
        let screenSize = idealTerminalSize()
        sshService.startShell(cols: screenSize.cols, rows: screenSize.rows)

        // Wait a moment for the shell to be ready
        dlog("Shell started (\(screenSize.cols)x\(screenSize.rows)), waiting before launching tmux...")
        try? await Task.sleep(for: .milliseconds(500))

        // Unlock Mac keychain if configured
        if host.unlockMacKeychain {
            await unlockMacKeychain()
        }

        // Start tmux if enabled, otherwise stay in single-pane mode
        if host.useTmux {
            await startTmux(screenSize: screenSize)
        }
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

    private func startTmux(screenSize: (cols: Int, rows: Int)) async {
        usingTmux = true

        // Launch tmux control mode
        let launchCmd: String
        if host.tmuxSessionName.isEmpty {
            // Standalone session
            launchCmd = tmuxService.launchCommand(sessionName: "speakterm")
        } else {
            // Attach to existing session group (shared with desktop)
            launchCmd = tmuxService.launchCommand(
                sessionName: "\(host.tmuxSessionName)-mobile",
                groupWith: host.tmuxSessionName
            )
        }
        dlog("Launching tmux: \(launchCmd.trimmingCharacters(in: .whitespacesAndNewlines))")
        sshService.write(launchCmd)

        // Wait for tmux to start and send initial data
        try? await Task.sleep(for: .seconds(1))

        // Set tmux client size to match device screen
        dlog("Setting tmux client size to \(screenSize.cols)x\(screenSize.rows)")
        tmuxService.sendFireAndForget(.refreshClient(width: screenSize.cols, height: screenSize.rows))
        try? await Task.sleep(for: .milliseconds(300))

        // Query initial state
        dlog("Querying tmux panes and windows...")
        await refreshPanes()
        await refreshWindows()
        dlog("tmux ready: \(self.paneViewModels.count) panes, \(self.windows.count) windows")
        // Note: capture happens automatically in updatePaneViewModels for new panes

        isTmuxReady = true
        startStatePolling()
    }

    // MARK: - tmux Notifications

    private func handleTmuxNotification(_ notification: TmuxNotification) {
        switch notification {
        case .output(let pane, let data):
            // Route output to the correct pane's TerminalView
            if let paneVM = paneViewModels.first(where: { $0.paneID == pane }) {
                paneVM.feedData(data)
            }
            // Feed to state detection
            stateDetection.recordOutput(pane: pane, data: data)

        case .layoutChange:
            // Only refresh if pane count might have changed (split/close).
            // Size-only changes from refresh-client are handled by syncTmuxClientSize dedup.
            // Use debounce to avoid rapid-fire refreshes.
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
            // Could update UI title
            break

        case .paneModeChanged(let pane, _):
            // Immediately re-detect state for this pane
            if let paneVM = paneViewModels.first(where: { $0.paneID == pane }) {
                let state = stateDetection.detectState(pane: pane, currentCommand: paneVM.pane.currentCommand)
                paneVM.paneState = state
                stateVersion += 1
            }

        case .exit:
            usingTmux = false
            isTmuxReady = false
        }
    }

    // MARK: - Pane Management

    func refreshPanes() async {
        let response = await tmuxService.send(.listPanes())
        guard !response.isError else {
            dlog("list-panes error: \(response.output)")
            return
        }

        let panes = tmuxService.parsePaneList(response.output)
        dlog("Parsed \(panes.count) panes: \(panes.map { "\($0.id) \($0.width)x\($0.height) at \($0.x),\($0.y)" })")
        updatePaneViewModels(panes)
    }

    func refreshWindows() async {
        let response = await tmuxService.send(.listWindows())
        guard !response.isError else { return }
        windows = tmuxService.parseWindowList(response.output)
    }

    private func updatePaneViewModels(_ panes: [Pane]) {
        let existingIDs = Set(paneViewModels.map(\.paneID))
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

        // Capture history for newly appeared panes (window switch, split, etc.)
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

        // Update active pane
        if let active = panes.first(where: { $0.isActive }) {
            activePaneID = active.id
        }
    }

    // MARK: - Actions

    func splitPane(horizontal: Bool) {
        // Select the active pane first, then split it
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

    /// Resize a pane by N cells in a direction (L/R/U/D)
    func resizePaneBy(_ paneID: TmuxPaneID, direction: String, amount: Int) {
        tmuxService.sendFireAndForget(.resizePaneBy(id: paneID, direction: direction, amount: amount))
    }

    /// Toggle tmux zoom on a pane (like prefix-z)
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

    /// Escape a string for use in a shell command
    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func resizeTerminal(cols: Int, rows: Int) {
        sshService.resize(cols: cols, rows: rows)
    }

    func killSession() {
        if host.tmuxSessionName.isEmpty {
            tmuxService.sendFireAndForget(.killSession(name: "speakterm"))
        } else {
            tmuxService.sendFireAndForget(.killSession(name: "\(host.tmuxSessionName)-mobile"))
        }
        disconnect()
    }

    func disconnect() {
        statePollingTask?.cancel()
        statePollingTask = nil
        sshService.disconnect()
        usingTmux = false
        isTmuxReady = false
        paneViewModels = []
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
        for paneVM in paneViewModels {
            let newState = stateDetection.detectState(
                pane: paneVM.paneID,
                currentCommand: paneVM.pane.currentCommand
            )
            if paneVM.paneState != newState {
                paneVM.paneState = newState
                changed = true
            }
        }
        if changed {
            stateVersion += 1
        }
    }

    /// Capture existing pane content on (re)connect.
    /// Feeds content to both TerminalView (for display) and StateDetection (for state).
    private func captureInitialPaneHistory() async {
        for paneVM in paneViewModels {
            // Capture the full visible area (pane height lines from bottom)
            let lines = paneVM.pane.height > 0 ? paneVM.pane.height : 50
            let resp = await tmuxService.send(.capturePane(id: paneVM.paneID, lines: lines))
            if !resp.isError {
                let text = resp.output
                // Convert \n to \r\n for proper terminal rendering
                let termText = text.replacingOccurrences(of: "\n", with: "\r\n")
                if let data = termText.data(using: .utf8) {
                    // Feed to TerminalView for display (buffers if UI not ready yet)
                    paneVM.feedData(data)
                }
                // Feed raw text to state detection (only last 10 lines matter)
                if let rawData = text.data(using: .utf8) {
                    stateDetection.recordOutput(pane: paneVM.paneID, data: rawData)
                }
            }
        }
        updatePaneStates()
    }
}
