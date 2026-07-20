import ACPKit
import Foundation

/// Spawns an agent and hands back a started connection. Persistent
/// launchers (daemon/relay) also return the host transport + agent id so
/// sessions can detach/reattach.
public protocol AgentLauncher: Sendable {
    func launch(
        preset: ACPAgentPreset, cwd: String, handler: any ACPClientHandler
    ) async throws -> AgentLaunch
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
