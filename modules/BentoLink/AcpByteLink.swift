import Foundation

/// Everything needed to reach one paired daemon over a sealed link. The
/// name says SEALED, not relay: the signed X25519 handshake belongs to the
/// pairing, and a future LAN-direct link runs the exact same seal — only
/// the bearer underneath changes.
public struct AcpSealedConfig: Sendable {
    public var relayBaseURL: String
    public var daemonID: String
    public var deviceID: String
    /// Raw 32-byte Ed25519 private key (Curve25519.Signing rawRepresentation).
    public var devicePrivateKey: Data
    /// "SHA256:..." host-key fingerprint pinned at pairing time.
    public var hostKeyFingerprint: String

    public init(
        relayBaseURL: String, daemonID: String, deviceID: String,
        devicePrivateKey: Data, hostKeyFingerprint: String
    ) {
        self.relayBaseURL = relayBaseURL
        self.daemonID = daemonID
        self.deviceID = deviceID
        self.devicePrivateKey = devicePrivateKey
        self.hostKeyFingerprint = hostKeyFingerprint
    }
}

public enum AcpHostEvent: Sendable {
    case agentExited(code: Int, message: String?)
    case detachedByAnotherClient
    case turnFinishedWhileDetached(stopReason: String)
    /// Another viewer started a turn on this agent. The prompting client
    /// infers this from its own send; everyone else has no other way to
    /// know, and would show an idle pane while output streams in.
    case turnStartedElsewhere
    /// An agent request this client may still be showing was answered by
    /// someone else — first answer wins, so drop the card.
    case agentRequestAnswered(requestID: String)
    case stderrLine(String)
    /// Another client wrote the daemon statekv key — re-pull it.
    case stateChanged(key: String)

    /// Re-deliverable by other means (a statekv poke is re-pulled anyway,
    /// stderr is diagnostics) — as opposed to the lifecycle events, which are
    /// sent exactly once and have no other path to the client.
    package var isTransientChatter: Bool {
        switch self {
        case .stderrLine, .stateChanged: return true
        case .agentExited, .detachedByAnotherClient, .turnFinishedWhileDetached,
             .turnStartedElsewhere, .agentRequestAnswered:
            return false
        }
    }
}

/// One agent row from the daemon's `list` op.
public struct AgentInstanceInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var cmd: String
    public var cwd: String
    public var running: Bool
    public var attached: Bool
    public var turnActive: Bool
    public var awaitingPerm: Bool
    public var acpSessionId: String?
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, cmd, cwd, running, attached
        case turnActive = "turn_active"
        case awaitingPerm = "awaiting_perm"
        case acpSessionId = "acp_session_id"
        case createdAt = "created_at"
    }
}

/// State reported by the daemon when a stream binds to an agent.
public struct AttachInfo: Sendable {
    public var agentID: String
    public var running: Bool
    public var turnActive: Bool
    public var acpSessionID: String?
    /// Scrollback bounds at attach time (0/1 on a fresh log) and whether the
    /// daemon granted a point-to-point catch-up replay. `replay == true`
    /// means the missing updates stream in right after this reply — history
    /// arrives without a session/load, so don't issue one for the transcript.
    public var headSeq: UInt64
    public var startSeq: UInt64
    public var replay: Bool

    public init(agentID: String, running: Bool, turnActive: Bool,
                acpSessionID: String? = nil,
                headSeq: UInt64 = 0, startSeq: UInt64 = 0, replay: Bool = false) {
        self.agentID = agentID
        self.running = running
        self.turnActive = turnActive
        self.acpSessionID = acpSessionID
        self.headSeq = headSeq
        self.startSeq = startSeq
        self.replay = replay
    }
}

/// Raw bidirectional byte channel beneath the acphost unit protocol —
/// WSS through the relay, or a local unix socket.
public protocol AcpByteLink: AnyObject, Sendable {
    var incoming: AsyncThrowingStream<Data, Error> { get }
    func open() async throws
    func send(_ data: Data) async throws
    func close()
}

/// The historical name, kept as an alias so existing call sites read on.
public typealias AcpRelayConfig = AcpSealedConfig
