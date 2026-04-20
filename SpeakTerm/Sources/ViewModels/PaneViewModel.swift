import Foundation
import SwiftUI

/// ViewModel for a single tmux pane, managing its terminal output and input.
@MainActor
final class PaneViewModel: ObservableObject, Identifiable {
    nonisolated let paneID: TmuxPaneID
    @Published var pane: Pane
    @Published var isActive: Bool = false

    /// Called by TerminalView delegate when data needs to be sent
    nonisolated(unsafe) var onDataReceived: (@Sendable (Data) -> Void)?

    private let tmuxService: TmuxControlModeService

    nonisolated var id: TmuxPaneID { paneID }

    init(pane: Pane, tmuxService: TmuxControlModeService) {
        self.paneID = pane.id
        self.pane = pane
        self.isActive = pane.isActive
        self.tmuxService = tmuxService
    }

    /// Send raw terminal input to this pane
    func sendInput(_ data: Data) {
        tmuxService.sendData(to: paneID, data: data)
    }

    func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    func updatePane(_ newPane: Pane) {
        self.pane = newPane
    }
}
