import Foundation
import SwiftUI
import SwiftTmux

/// ViewModel for a single tmux pane, managing its terminal output and input.
@MainActor
public final class PaneViewModel: ObservableObject, Identifiable {
    public nonisolated let paneID: TmuxPaneID
    @Published public var pane: Pane
    @Published public var isActive: Bool = false
    @Published public var paneState: PaneState = .idle

    /// True when a coding-agent pane has finished (.idle) but the user hasn't
    /// looked at it yet — the "done, unseen" state (herdr's done vs idle). Set
    /// when an agent pane goes idle while not focused; cleared when it's focused
    /// or leaves idle. Drives the distinct "done" dot.
    @Published public var agentFinishedUnseen: Bool = false

    /// Called when terminal output arrives for this pane. Setting this also
    /// replays the full history buffer so a freshly-bound surface (e.g.
    /// after navigating away and back) repaints the scrollback rather than
    /// showing an empty screen until the next byte arrives.
    public nonisolated(unsafe) var onDataReceived: (@Sendable (Data) -> Void)? {
        didSet {
            guard let onDataReceived, !_history.isEmpty else { return }
            onDataReceived(_history)
        }
    }

    /// Rolling buffer of every byte received for this pane. Capped so a
    /// long-running session doesn't grow without bound.
    nonisolated(unsafe) private var _history = Data()
    private static let maxHistoryBytes = 256 * 1024

    /// Strips screen/tmux window-title escapes from this pane's byte stream
    /// (see ScreenTitleStripper). Stateful, so it must persist across chunks.
    private let titleStripper = ScreenTitleStripper()

    /// Feed data to this pane — appended to history and forwarded if bound.
    public func feedData(_ data: Data) {
        let clean = titleStripper.strip(data)
        guard !clean.isEmpty else { return }
        appendHistory(clean)
        onDataReceived?(clean)
    }

    private func appendHistory(_ data: Data) {
        _history.append(data)
        let overflow = _history.count - Self.maxHistoryBytes
        if overflow > 0 {
            _history.removeSubrange(0..<overflow)
        }
    }

    private let tmuxService: TmuxControlMode

    public nonisolated var id: TmuxPaneID { paneID }

    public init(pane: Pane, tmuxService: TmuxControlMode) {
        self.paneID = pane.id
        self.pane = pane
        self.isActive = pane.isActive
        self.tmuxService = tmuxService
    }

    /// Send raw terminal input to this pane
    public func sendInput(_ data: Data) {
        tmuxService.sendData(to: paneID, data: data)
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    public func updatePane(_ newPane: Pane) {
        self.pane = newPane
    }
}
