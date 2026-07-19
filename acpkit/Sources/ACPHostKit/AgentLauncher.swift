import ACPKit
import Foundation

/// Spawns an agent and hands back a started connection. Persistent
/// launchers (daemon/relay) also return the host transport + agent id so
/// sessions can detach/reattach.
public protocol AgentLauncher: Sendable {
    func launch(
        preset: AgentPreset, cwd: String, handler: any ACPClientHandler
    ) async throws -> AgentLaunch
}

#if os(macOS)
/// In-process fallback (no daemon running): agent dies with the app.
public struct LocalAgentLauncher: AgentLauncher {
    public init() {}

    public func launch(
        preset: AgentPreset, cwd: String, handler: any ACPClientHandler
    ) async throws -> AgentLaunch {
        let transport = ProcessTransport(
            command: preset.command,
            arguments: preset.args,
            cwd: cwd,
            environment: preset.env)
        try transport.start()
        let connection = ACPConnection(transport: transport, handler: handler)
        await connection.start()
        return AgentLaunch(connection: connection, transport: nil, attachInfo: nil)
    }
}
#endif

/// Record for resuming sessions across app restarts (the agent keeps the
/// conversation on disk; we keep the pointer).
public struct SessionRecord: Codable, Sendable, Equatable {
    public var presetId: String
    public var customPreset: AgentPreset?
    public var cwd: String
    public var acpSessionId: String
    public var title: String

    public init(presetId: String, customPreset: AgentPreset? = nil, cwd: String,
                acpSessionId: String, title: String) {
        self.presetId = presetId
        self.customPreset = customPreset
        self.cwd = cwd
        self.acpSessionId = acpSessionId
        self.title = title
    }
}
