import Foundation
import SwiftUI

/// ViewModel for a single tmux pane, managing its terminal output and input.
@MainActor
final class PaneViewModel: ObservableObject, Identifiable {
    nonisolated let paneID: TmuxPaneID
    @Published var pane: Pane
    @Published var isActive: Bool = false
    @Published var paneState: PaneState = .idle

    /// Called when terminal output arrives for this pane.
    nonisolated(unsafe) var onDataReceived: (@Sendable (Data) -> Void)? {
        didSet {
            // Flush any buffered data that arrived before the callback was set
            guard let onDataReceived else { return }
            let buffered = _pendingData
            _pendingData.removeAll()
            for chunk in buffered {
                onDataReceived(chunk)
            }
        }
    }

    /// Buffer for data that arrives before onDataReceived is set
    nonisolated(unsafe) private var _pendingData: [Data] = []

    /// Feed data to this pane — buffers if callback not yet set
    func feedData(_ data: Data) {
        if let onDataReceived {
            onDataReceived(data)
        } else {
            _pendingData.append(data)
        }
    }

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
