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

    let host: Host
    let sshService = SSHService()
    let tmuxService = TmuxControlModeService()

    /// For non-tmux fallback: direct terminal data callback
    nonisolated(unsafe) var onRawDataReceived: (@Sendable (Data) -> Void)?

    /// Whether we're using tmux control mode
    nonisolated(unsafe) private(set) var usingTmux = false

    private var layoutChangeDebounce: Task<Void, Never>?

    init(host: Host) {
        self.host = host
        setupCallbacks()
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

        sshService.startShell(cols: 80, rows: 24)

        // Wait a moment for the shell to be ready, then try tmux
        dlog("Shell started, waiting before launching tmux...")
        try? await Task.sleep(for: .milliseconds(500))
        await startTmux()
    }

    private func startTmux() async {
        usingTmux = true

        // Launch tmux control mode
        let launchCmd = tmuxService.launchCommand(sessionName: "speakterm")
        dlog("Launching tmux: \(launchCmd.trimmingCharacters(in: .whitespacesAndNewlines))")
        sshService.write(launchCmd)

        // Wait for tmux to start and send initial data
        try? await Task.sleep(for: .seconds(1))

        // Query initial state
        dlog("Querying tmux panes and windows...")
        await refreshPanes()
        await refreshWindows()
        dlog("tmux ready: \(self.paneViewModels.count) panes, \(self.windows.count) windows")
        isTmuxReady = true
    }

    // MARK: - tmux Notifications

    private func handleTmuxNotification(_ notification: TmuxNotification) {
        switch notification {
        case .output(let pane, let data):
            // Route output to the correct pane's TerminalView
            if let paneVM = paneViewModels.first(where: { $0.paneID == pane }) {
                paneVM.onDataReceived?(data)
            }

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

        case .paneModeChanged:
            // Will be used for state machine later
            break

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
        // Update existing or create new PaneViewModels
        var newViewModels: [PaneViewModel] = []

        for pane in panes {
            if let existing = paneViewModels.first(where: { $0.paneID == pane.id }) {
                existing.updatePane(pane)
                existing.isActive = pane.isActive
                newViewModels.append(existing)
            } else {
                let vm = PaneViewModel(pane: pane, tmuxService: tmuxService)
                vm.isActive = pane.isActive
                newViewModels.append(vm)
            }
        }

        paneViewModels = newViewModels

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
        tmuxService.sendFireAndForget(.selectPane(id: paneID))
        activePaneID = paneID
        for vm in paneViewModels {
            vm.isActive = (vm.paneID == paneID)
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

    func resizeTerminal(cols: Int, rows: Int) {
        sshService.resize(cols: cols, rows: rows)
    }

    func disconnect() {
        sshService.disconnect()
        usingTmux = false
        isTmuxReady = false
        paneViewModels = []
    }
}
