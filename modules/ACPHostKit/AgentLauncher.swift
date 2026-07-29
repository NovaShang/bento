import ACPKit
import Foundation

/// Spawns an agent and hands back a started connection. Persistent
/// launchers (daemon/relay) also return the host transport + agent id so
/// sessions can detach/reattach.
public protocol AgentLauncher: Sendable {
    /// Start an agent. `conversationID` names the ACP session this process
    /// is for when one is being RESUMED: daemon-hosted launchers turn that
    /// into an ensure (adopt the live agent for that conversation rather
    /// than start a second one on the same history) and serve the backlog
    /// from its durable log — hence `haveSeq`, the caller's catch-up cursor.
    /// nil = a brand-new conversation, so always a fresh process.
    func launch(
        preset: ACPAgentPreset, cwd: String, conversationID: String?, haveSeq: UInt64,
        holdsTranscript: Bool, handler: any ACPClientHandler
    ) async throws -> AgentLaunch
}

public extension AgentLauncher {
    /// Fresh conversation, no cursor.
    func launch(
        preset: ACPAgentPreset, cwd: String, handler: any ACPClientHandler
    ) async throws -> AgentLaunch {
        try await launch(preset: preset, cwd: cwd, conversationID: nil, haveSeq: 0,
                         holdsTranscript: false, handler: handler)
    }
}

/// Record for resuming sessions across app restarts (the agent keeps the
/// conversation on disk; we keep the pointer).
public struct SessionRecord: Codable, Sendable, Equatable {
    public var presetId: String
    public var customPreset: ACPAgentPreset?
    public var cwd: String
    public var acpSessionId: String
    public var title: String

    public init(presetId: String, customPreset: ACPAgentPreset? = nil, cwd: String,
                acpSessionId: String, title: String) {
        self.presetId = presetId
        self.customPreset = customPreset
        self.cwd = cwd
        self.acpSessionId = acpSessionId
        self.title = title
    }
}
