#if os(macOS)
import ACPKit
import ACPHostKit
import Foundation

/// The Mac launch policy: daemon-hosted whenever the daemon's unix socket is
/// up (agents live in the daemon and SURVIVE the app — the tmux-server
/// analogue), falling back to an in-process spawn when it isn't (agent dies
/// with the app, exactly the old no-tmux semantics). Attach/control always
/// target the daemon — only it can hold detached agents.
public struct AdaptiveMacLauncher: PersistentAgentLauncher {
    let daemon = DaemonAgentLauncher()
    let local = LocalAgentLauncher()

    public init() {}

    public func launch(
        preset: ACPAgentPreset, cwd: String, handler: any ACPClientHandler
    ) async throws -> AgentLaunch {
        if daemon.socketExists {
            return try await daemon.launch(preset: preset, cwd: cwd, handler: handler)
        }
        return try await local.launch(preset: preset, cwd: cwd, handler: handler)
    }

    public func attach(agentID: String, handler: any ACPClientHandler) async throws -> AgentLaunch {
        try await daemon.attach(agentID: agentID, handler: handler)
    }

    public func makeControl() async throws -> AcpHostTransport {
        try await daemon.makeControl()
    }
}
#endif
