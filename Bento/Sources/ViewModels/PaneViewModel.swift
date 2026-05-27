import Foundation
import SwiftUI
import SwiftTmux

/// ViewModel for a single tmux pane, managing its terminal output and input.
@MainActor
final class PaneViewModel: ObservableObject, Identifiable {
    nonisolated let paneID: TmuxPaneID
    @Published var pane: Pane
    @Published var isActive: Bool = false
    @Published var paneState: PaneState = .idle

    /// Called when terminal output arrives for this pane. Setting this also
    /// replays the full history buffer so a freshly-bound TerminalView (e.g.
    /// after navigating away and back) repaints the scrollback rather than
    /// showing an empty screen until the next byte arrives.
    nonisolated(unsafe) var onDataReceived: (@Sendable (Data) -> Void)? {
        didSet {
            guard let onDataReceived, !_history.isEmpty else { return }
            onDataReceived(_history)
        }
    }

    /// Rolling buffer of every byte received for this pane. Capped so a
    /// long-running session doesn't grow without bound.
    nonisolated(unsafe) private var _history = Data()
    private static let maxHistoryBytes = 256 * 1024

    /// Feed data to this pane — appended to history and forwarded if bound.
    func feedData(_ data: Data) {
        appendHistory(data)
        onDataReceived?(data)
    }

    private func appendHistory(_ data: Data) {
        _history.append(data)
        let overflow = _history.count - Self.maxHistoryBytes
        if overflow > 0 {
            _history.removeSubrange(0..<overflow)
        }
    }

    private let tmuxService: TmuxControlMode

    nonisolated var id: TmuxPaneID { paneID }

    init(pane: Pane, tmuxService: TmuxControlMode) {
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
