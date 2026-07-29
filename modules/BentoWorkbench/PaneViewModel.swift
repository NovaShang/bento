import BentoFoundation
import BentoUI
import Foundation
import SwiftUI

/// ViewModel for a single workspace pane: identity + geometry + activity
/// state, and input routing into the pane's agent composer.
@MainActor
public final class PaneViewModel: ObservableObject, Identifiable {
    public nonisolated let paneID: PaneID
    @Published public var pane: Pane
    @Published public var isActive: Bool = false
    @Published public var paneState: PaneState = .idle

    /// True when a pane has finished (.idle) but the user hasn't looked at it
    /// yet — the "done, unseen" state. Set when a pane goes idle while not
    /// focused; cleared when it's focused or leaves idle. Drives the green ✓.
    @Published public var agentFinishedUnseen: Bool = false

    /// The workspace store owning this pane's agent runtime; nil only in
    /// previews/tests.
    private weak var workspace: AgentWorkspaceStore?

    public nonisolated var id: PaneID { paneID }

    public init(pane: Pane, workspace: AgentWorkspaceStore?) {
        self.paneID = pane.id
        self.pane = pane
        self.isActive = pane.isActive
        self.workspace = workspace
    }

    /// Send raw input to this pane: printable text lands in the agent's
    /// composer; CR submits the draft.
    public func sendInput(_ data: Data) {
        workspace?.routeInput(data, to: paneID.raw)
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    public func updatePane(_ newPane: Pane) {
        // Equality-gate: the 2s poll re-applies an identical Pane most
        // cycles; republishing would ripple objectWillChange through every
        // subscribed view for no visible change.
        guard pane != newPane else { return }
        self.pane = newPane
    }

    /// The pane's working directory, read from the workspace record. Used by
    /// file preview to resolve relative paths.
    public func currentWorkingDirectory() async -> String? {
        let path = workspace?.paneCwd(paneID.raw)
        return path?.hasPrefix("/") == true ? path : nil
    }
}
