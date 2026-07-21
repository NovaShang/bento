import ACPKit
import Foundation

/// Result of launching or attaching to an agent. `transport` and
/// `attachInfo` carry the daemon/relay handle used to detach and reattach.
public struct AgentLaunch: Sendable {
    public let connection: ACPConnection
    public let transport: AcpHostTransport?
    public let attachInfo: AttachInfo?

    public init(connection: ACPConnection, transport: AcpHostTransport?,
                attachInfo: AttachInfo?) {
        self.connection = connection
        self.transport = transport
        self.attachInfo = attachInfo
    }
}

/// Launchers that host agents in the daemon: agents survive the client,
/// can be listed, and reattached (from any paired device).
public protocol PersistentAgentLauncher: AgentLauncher {
    /// Short-lived control connection (list agents, browse directories).
    func makeControl() async throws -> AcpHostTransport
    /// Attach to an existing agent instance.
    func attach(agentID: String, handler: any ACPClientHandler) async throws -> AgentLaunch
}

/// Launches agents on the paired Mac through the relay.
public struct RemoteAgentLauncher: PersistentAgentLauncher {
    public let config: AcpRelayConfig

    public init(config: AcpRelayConfig) {
        self.config = config
    }

    public func launch(
        preset: ACPAgentPreset, cwd: String, handler: any ACPClientHandler
    ) async throws -> AgentLaunch {
        let transport = AcpHostTransportFactory.relay(config: config)
        try await transport.connect()
        let info = try await transport.spawn(
            command: preset.command, args: preset.args, cwd: cwd, env: preset.env)
        let connection = ACPConnection(transport: transport, handler: handler)
        await connection.start()
        return AgentLaunch(connection: connection, transport: transport, attachInfo: info)
    }

    public func attach(agentID: String, handler: any ACPClientHandler) async throws -> AgentLaunch {
        let transport = AcpHostTransportFactory.relay(config: config)
        try await transport.connect()
        let info = try await transport.attach(agentID: agentID)
        let connection = ACPConnection(transport: transport, handler: handler)
        await connection.start()
        return AgentLaunch(connection: connection, transport: transport, attachInfo: info)
    }

    public func makeControl() async throws -> AcpHostTransport {
        let transport = AcpHostTransportFactory.relay(config: config)
        try await transport.connect()
        return transport
    }
}

#if os(macOS)
/// Launches agents in the local daemon over its unix socket — the Mac
/// app's agents live in the daemon and survive app restarts, and appear in
/// the same session pool the iPhone sees.
public struct DaemonAgentLauncher: PersistentAgentLauncher {
    public let socketPath: String

    public init(socketPath: String? = nil) {
        if let socketPath {
            self.socketPath = socketPath
        } else {
            // Must match the home the daemon actually runs in — the macOS app's
            // BentoCLI starts/manages the daemon under ~/.bento-acp (honoring
            // $BENTO_HOME). Defaulting to ~/.bento here connected the GUI to a
            // DIFFERENT daemon than the one it launched.
            let home = ProcessInfo.processInfo.environment["BENTO_HOME"].map {
                URL(fileURLWithPath: $0)
            } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bento-acp")
            self.socketPath = home.appendingPathComponent("acp.sock").path
        }
    }

    public var socketExists: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    public func launch(
        preset: ACPAgentPreset, cwd: String, handler: any ACPClientHandler
    ) async throws -> AgentLaunch {
        guard socketExists else { throw AcpHostError.daemonNotRunning }
        let transport = AcpHostTransportFactory.local(socketPath: socketPath)
        try await transport.connect()
        let info = try await transport.spawn(
            command: preset.command, args: preset.args, cwd: cwd, env: preset.env)
        let connection = ACPConnection(transport: transport, handler: handler)
        await connection.start()
        return AgentLaunch(connection: connection, transport: transport, attachInfo: info)
    }

    public func attach(agentID: String, handler: any ACPClientHandler) async throws -> AgentLaunch {
        guard socketExists else { throw AcpHostError.daemonNotRunning }
        let transport = AcpHostTransportFactory.local(socketPath: socketPath)
        try await transport.connect()
        let info = try await transport.attach(agentID: agentID)
        let connection = ACPConnection(transport: transport, handler: handler)
        BentoReplayTrace.attach(to: connection)  // TEMP diagnostic — remove
        await connection.start()
        return AgentLaunch(connection: connection, transport: transport, attachInfo: info)
    }

    public func makeControl() async throws -> AcpHostTransport {
        guard socketExists else { throw AcpHostError.daemonNotRunning }
        let transport = AcpHostTransportFactory.local(socketPath: socketPath)
        try await transport.connect()
        return transport
    }
}
#endif
