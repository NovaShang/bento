import CryptoKit
import Foundation

// Client side of the daemon's acphost stream protocol. Wire format is
// specified in desktop/internal/acphost/proto.go (the Go host is the
// canonical implementation; cross-impl vectors live in
// Tests/BentoAgentCoreTests/Fixtures/acphost-vectors.json).

public enum AcpHostProtocol {
    public static let version = 1
    /// Receive-side sanity cap on one unit — breaching it tears the
    /// transport, so senders chunk below it (see stdioChunk).
    public static let maxUnit = 1 << 20
    /// Max stdio payload per unit. One JSON-RPC line spans several units
    /// when longer; both ends reassemble on newlines, so chunk boundaries
    /// carry no meaning (mirrors Go's StdioChunk).
    public static let stdioChunk = 256 * 1024
    static let unitTypeControl: UInt8 = 0x01
    static let unitTypeStdio: UInt8 = 0x02

    static func helloSigMessage(daemonID: String, deviceID: String, ts: Int64, ephPubB64: String) -> Data {
        Data("bento-acp-hello:v1:\(daemonID):\(deviceID):\(ts):\(ephPubB64)".utf8)
    }

    static func welcomeSigMessage(
        daemonID: String, deviceID: String, ts: Int64, clientEphB64: String, hostEphB64: String
    ) -> Data {
        Data("bento-acp-welcome:v1:\(daemonID):\(deviceID):\(ts):\(clientEphB64):\(hostEphB64)".utf8)
    }

    /// HKDF-SHA256 directional keys, matching Go's deriveKeys.
    static func deriveKeys(
        shared: SharedSecret, daemonID: String, deviceID: String
    ) -> (c2s: SymmetricKey, s2c: SymmetricKey) {
        let salt = Data("bento-acp-v1:\(daemonID):\(deviceID)".utf8)
        let c2s = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("c2s".utf8), outputByteCount: 32)
        let s2c = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("s2c".utf8), outputByteCount: 32)
        return (c2s, s2c)
    }

    /// SSH-wire SHA256 fingerprint of a raw Ed25519 key — same string the
    /// pairing ack pinned (Go: ssh.FingerprintSHA256, "SHA256:" + raw-b64).
    public static func sshFingerprint(rawEd25519PublicKey: Data) -> String {
        var wire = Data()
        func sshString(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            withUnsafeBytes(of: &len) { wire.append(contentsOf: $0) }
            wire.append(d)
        }
        sshString(Data("ssh-ed25519".utf8))
        sshString(rawEd25519PublicKey)
        let digest = SHA256.hash(data: wire)
        let b64 = Data(digest).base64EncodedString()
        return "SHA256:" + b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// One direction of the sealed channel: counter nonces, ct||tag boxes.
struct AcpBoxer {
    let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    private mutating func nextNonce() -> Data {
        var nonce = Data(count: 12)
        var c = counter.littleEndian
        withUnsafeBytes(of: &c) { raw in
            for (i, byte) in raw.enumerated() { nonce[4 + i] = byte }
        }
        counter += 1
        return nonce
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: nextNonce())
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        return box.ciphertext + box.tag
    }

    mutating func open(_ box: Data) throws -> Data {
        guard box.count >= 16 else { throw AcpHostError.protocolError("sealed unit too short") }
        let nonce = try ChaChaPoly.Nonce(data: nextNonce())
        let sealed = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: box.dropLast(16),
            tag: box.suffix(16))
        return try ChaChaPoly.open(sealed, using: key)
    }
}

/// Reassembles 4-byte-BE length-prefixed units (mirror of Go unitBuffer).
struct AcpUnitBuffer {
    private var buf = Data()

    mutating func append(_ p: Data) throws -> [Data] {
        buf.append(p)
        var units: [Data] = []
        while buf.count >= 4 {
            let n = buf.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard n <= AcpHostProtocol.maxUnit else {
                throw AcpHostError.protocolError("unit too large: \(n)")
            }
            guard buf.count >= 4 + n else { break }
            units.append(Data(buf.dropFirst(4).prefix(n)))
            buf = Data(buf.dropFirst(4 + n))
        }
        return units
    }
}

func acpPrefixUnit(_ body: Data) -> Data {
    var out = Data()
    var len = UInt32(body.count).bigEndian
    withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
    out.append(body)
    return out
}

// MARK: - Wire messages

struct AcpHello: Codable {
    var v: Int
    var deviceId: String
    var ts: Int64
    var ephPub: String
    var sig: String

    enum CodingKeys: String, CodingKey {
        case v
        case deviceId = "device_id"
        case ts
        case ephPub = "eph_pub"
        case sig
    }
}

struct AcpWelcome: Codable {
    var v: Int?
    var ephPub: String?
    var hostPub: String?
    var sig: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case v
        case ephPub = "eph_pub"
        case hostPub = "host_pub"
        case sig
        case error
    }
}

public struct AcpDirEntry: Codable, Sendable, Hashable {
    public var name: String
    public var dir: Bool
}

struct AcpControl: Codable {
    var op: String
    var cmd: String?
    var args: [String]?
    var cwd: String?
    var env: [String: String]?
    var bytes: Int64?
    var path: String?
    var code: Int?
    var error: String?
    var line: String?
    var entries: [AcpDirEntry]?
    var agentId: String?
    var key: String?
    var data: String?
    /// filedata: further chunks follow (large files arrive split).
    var more: Bool?
    var running: Bool?
    var turnActive: Bool?
    var acpSessionId: String?
    var agents: [AgentInstanceInfo]?

    enum CodingKeys: String, CodingKey {
        case op, cmd, args, cwd, env, bytes, path, code, error, line, entries, agents, data, key, more
        case agentId = "agent_id"
        case running
        case turnActive = "turn_active"
        case acpSessionId = "acp_session_id"
    }

    init(
        op: String, cmd: String? = nil, args: [String]? = nil, cwd: String? = nil,
        env: [String: String]? = nil, bytes: Int64? = nil, path: String? = nil,
        code: Int? = nil, error: String? = nil, line: String? = nil,
        entries: [AcpDirEntry]? = nil, agentId: String? = nil, key: String? = nil, data: String? = nil,
        running: Bool? = nil, turnActive: Bool? = nil, acpSessionId: String? = nil,
        agents: [AgentInstanceInfo]? = nil
    ) {
        self.op = op
        self.cmd = cmd
        self.args = args
        self.cwd = cwd
        self.env = env
        self.bytes = bytes
        self.path = path
        self.code = code
        self.error = error
        self.line = line
        self.entries = entries
        self.agentId = agentId
        self.key = key
        self.data = data
        self.running = running
        self.turnActive = turnActive
        self.acpSessionId = acpSessionId
        self.agents = agents
    }
}

public enum AcpHostError: Error, Sendable {
    case protocolError(String)
    case handshakeRejected(String)
    case hostKeyMismatch(pinned: String, presented: String)
    case spawnFailed(String)
    case connectionClosed
    case timeout(String)
    /// The local bento-daemon isn't running (its unix socket is absent).
    /// The Mac app starts the daemon on launch and can retry from the
    /// first-run window, so this surfaces as a loud, recoverable error
    /// rather than a silent in-process fallback.
    case daemonNotRunning
}
