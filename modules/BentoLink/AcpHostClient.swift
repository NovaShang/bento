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
    package static let unitTypeControl: UInt8 = 0x01
    package static let unitTypeStdio: UInt8 = 0x02

    package static func helloSigMessage(daemonID: String, deviceID: String, ts: Int64, ephPubB64: String) -> Data {
        Data("bento-acp-hello:v1:\(daemonID):\(deviceID):\(ts):\(ephPubB64)".utf8)
    }

    package static func welcomeSigMessage(
        daemonID: String, deviceID: String, ts: Int64, clientEphB64: String, hostEphB64: String
    ) -> Data {
        Data("bento-acp-welcome:v1:\(daemonID):\(deviceID):\(ts):\(clientEphB64):\(hostEphB64)".utf8)
    }

    /// HKDF-SHA256 directional keys, matching Go's deriveKeys.
    package static func deriveKeys(
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
package struct AcpBoxer {
    package let key: SymmetricKey

    package init(key: SymmetricKey) { self.key = key }
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

    package mutating func seal(_ plaintext: Data) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: nextNonce())
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        return box.ciphertext + box.tag
    }

    package mutating func open(_ box: Data) throws -> Data {
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
package struct AcpUnitBuffer {
    private var buf = Data()

    package init() {}

    package mutating func append(_ p: Data) throws -> [Data] {
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

package func acpPrefixUnit(_ body: Data) -> Data {
    var out = Data()
    var len = UInt32(body.count).bigEndian
    withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
    out.append(body)
    return out
}

// MARK: - Wire messages

package struct AcpHello: Codable {
    package var v: Int
    package var deviceId: String
    package var ts: Int64
    package var ephPub: String
    package var sig: String

    package init(v: Int, deviceId: String, ts: Int64, ephPub: String, sig: String) {
        self.v = v
        self.deviceId = deviceId
        self.ts = ts
        self.ephPub = ephPub
        self.sig = sig
    }

    enum CodingKeys: String, CodingKey {
        case v
        case deviceId = "device_id"
        case ts
        case ephPub = "eph_pub"
        case sig
    }
}

package struct AcpWelcome: Codable {
    package var v: Int?
    package var ephPub: String?
    package var hostPub: String?
    package var sig: String?
    package var error: String?

    package init(v: Int? = nil, ephPub: String? = nil, hostPub: String? = nil,
                 sig: String? = nil, error: String? = nil) {
        self.v = v
        self.ephPub = ephPub
        self.hostPub = hostPub
        self.sig = sig
        self.error = error
    }

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

/// One row of a `listtree` (treedata) response: a path relative to the listing
/// root, and whether it is a directory.
public struct AcpTreeEntry: Codable, Sendable, Hashable {
    public var rel: String
    public var dir: Bool
}

/// One row of a `tmuxpanes` (tmuxpanesdata) response: the per-pane
/// state-detection inputs (pane_current_command + pane_title) the structure
/// mirror deliberately excludes because they flap without structural
/// meaning, plus the pane's live working directory (pane_current_path —
/// same discipline: flaps with every cd, only meaningful fresh). Fresh at
/// each poll — the detection tick's list-panes.
public struct AcpTmuxPaneStatus: Codable, Sendable, Hashable {
    /// tmux pane id, "%N".
    public var pane: String
    public var command: String?
    public var title: String?
    /// pane_current_path, absolute; nil when unknown (or an older daemon).
    public var path: String?

    /// The pane's INTERACTION mode — same polled discipline as the fields
    /// above (it flaps with every TUI that starts or exits, so the structure
    /// mirror may not carry it). A client needs it because a surface only
    /// ever sees the output that arrives AFTER it binds: one opened while a
    /// fullscreen TUI was already running never saw the `?1049h` or the
    /// mouse-enable the program sent at startup.
    ///
    /// nil = an older daemon that doesn't report it (never "false" by
    /// assumption — that reading is what made every pane look like a plain
    /// shell).
    public var alternateOn: Bool?
    /// mouse_any_flag: the program wants the mouse, so the wheel and clicks
    /// are ITS events, not the surface's scrollback and selection.
    public var mouseAny: Bool?
    /// mouse_sgr_flag: report in SGR encoding rather than legacy X10.
    public var mouseSGR: Bool?
    /// pane_in_mode: tmux has the pane in copy-mode and owns the viewport.
    public var inMode: Bool?

    private enum CodingKeys: String, CodingKey {
        case pane, command, title, path
        case alternateOn = "alternate_on"
        case mouseAny = "mouse_any"
        case mouseSGR = "mouse_sgr"
        case inMode = "in_mode"
    }

    package init(pane: String, command: String? = nil, title: String? = nil,
                 path: String? = nil, alternateOn: Bool? = nil,
                 mouseAny: Bool? = nil, mouseSGR: Bool? = nil, inMode: Bool? = nil) {
        self.pane = pane
        self.command = command
        self.title = title
        self.path = path
        self.alternateOn = alternateOn
        self.mouseAny = mouseAny
        self.mouseSGR = mouseSGR
        self.inMode = inMode
    }
}

/// A `stat` (statdata) response: the daemon-resolved absolute path plus type.
public struct AcpFileStat: Sendable {
    public let resolvedPath: String
    public let size: Int64
    public let isDir: Bool
    public let isRegular: Bool
    /// Unix mod time (seconds); 0 when unknown.
    public let mtime: Int64

    package init(resolvedPath: String, size: Int64, isDir: Bool,
                 isRegular: Bool, mtime: Int64) {
        self.resolvedPath = resolvedPath
        self.size = size
        self.isDir = isDir
        self.isRegular = isRegular
        self.mtime = mtime
    }
}

package struct AcpControl: Codable {
    package var op: String
    package var cmd: String?
    package var args: [String]?
    package var cwd: String?
    package var env: [String: String]?
    package var bytes: Int64?
    package var path: String?
    package var code: Int?
    package var error: String?
    package var line: String?
    package var entries: [AcpDirEntry]?
    package var agentId: String?
    package var key: String?
    package var data: String?
    /// filedata: further chunks follow (large files arrive split).
    package var more: Bool?
    package var running: Bool?
    package var turnActive: Bool?
    package var acpSessionId: String?
    package var agents: [AgentInstanceInfo]?

    // File-preview extensions (bento-file API).
    package var size: Int64?                // statdata
    package var isDir: Bool?                 // statdata
    package var isRegular: Bool?            // statdata
    package var mtime: Int64?               // statdata
    package var tree: [AcpTreeEntry]?       // treedata
    package var maxDepth: Int?             // listtree bounds
    package var maxEntries: Int?
    package var maxDirs: Int?
    package var maxChildren: Int?

    // Sequenced-scrollback catch-up (attach request / attached reply).
    package var haveSeq: UInt64?
    package var catchup: Bool?
    package var headSeq: UInt64?
    package var startSeq: UInt64?
    package var replay: Bool?

    /// requestAnswered only: the agent request that was just answered.
    package var requestId: String?

    /// attach/spawn: this client asserting it already HOLDS the transcript
    /// (rendered, not merely delivered). Only the client can know that; the
    /// daemon guessing it from the cursor blanked eight live panes.
    package var holdsTranscript: Bool?

    /// spawn only: the conversation this process is being started for.
    /// Naming it makes the spawn an ENSURE — the daemon adopts a live agent
    /// for that conversation instead of starting a second one on the same
    /// history — and binds its durable event log before the agent speaks.
    /// For kind:"tmux" it is the tmux SESSION NAME being ensured instead
    /// ("" = "bento") — same field, same ensure semantics (proto.go).
    package var sessionId: String?

    /// spawn only: which kind of pane this stream wants. Absent/"acp" is
    /// the agent path; "tmux" is the daemon-managed tmux ensure. Unknown
    /// kinds are refused daemon-side, never defaulted.
    package var kind: String?

    /// spawn kind=tmux / structure / structureApplied|Failed: the tmux
    /// server target. Absent = "local".
    package var target: String?

    /// structureApplied only: the structure-mirror rev that already
    /// includes the op's effect ("read at rev≥N and you will see it").
    package var rev: UInt64?

    /// resize only: the pane's new size in cells (renderer-authoritative).
    package var cols: Int?
    package var rows: Int?

    /// tmuxpanesdata only: per-pane detection inputs (command + title) the
    /// structure mirror deliberately excludes — reply-only, never sent.
    package var panes: [AcpTmuxPaneStatus]?

    /// tmuxcapture/tmuxcapturedata: ask for the pane's whole scrollback as
    /// RENDERABLE bytes (`capture-pane -e -J -S -`) instead of the default
    /// plain visible screen. Echoed on the reply. This is the FRESH-BIND
    /// history source: tmux, not the daemon's event log, is the scrollback
    /// authority — a capture is bounded by the user's `history-limit`, a log
    /// replay grows with session lifetime.
    package var scrollback: Bool?

    package init(op: String, cmd: String? = nil, args: [String]? = nil, cwd: String? = nil, env: [String: String]? = nil, bytes: Int64? = nil, path: String? = nil, code: Int? = nil, error: String? = nil, line: String? = nil, entries: [AcpDirEntry]? = nil, agentId: String? = nil, key: String? = nil, data: String? = nil, more: Bool? = nil, running: Bool? = nil, turnActive: Bool? = nil, acpSessionId: String? = nil, agents: [AgentInstanceInfo]? = nil, size: Int64? = nil, isDir: Bool? = nil, isRegular: Bool? = nil, mtime: Int64? = nil, tree: [AcpTreeEntry]? = nil, maxDepth: Int? = nil, maxEntries: Int? = nil, maxDirs: Int? = nil, maxChildren: Int? = nil, haveSeq: UInt64? = nil, catchup: Bool? = nil, headSeq: UInt64? = nil, startSeq: UInt64? = nil, replay: Bool? = nil, requestId: String? = nil, holdsTranscript: Bool? = nil, sessionId: String? = nil, kind: String? = nil, target: String? = nil, rev: UInt64? = nil, cols: Int? = nil, rows: Int? = nil, scrollback: Bool? = nil) {
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
        self.more = more
        self.running = running
        self.turnActive = turnActive
        self.acpSessionId = acpSessionId
        self.agents = agents
        self.size = size
        self.isDir = isDir
        self.isRegular = isRegular
        self.mtime = mtime
        self.tree = tree
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
        self.maxDirs = maxDirs
        self.maxChildren = maxChildren
        self.haveSeq = haveSeq
        self.catchup = catchup
        self.headSeq = headSeq
        self.startSeq = startSeq
        self.replay = replay
        self.requestId = requestId
        self.holdsTranscript = holdsTranscript
        self.sessionId = sessionId
        self.kind = kind
        self.target = target
        self.rev = rev
        self.cols = cols
        self.rows = rows
        self.scrollback = scrollback
    }

    enum CodingKeys: String, CodingKey {
        case op, cmd, args, cwd, env, bytes, path, code, error, line, entries, agents, data, key, more
        case kind, target, rev, cols, rows
        case agentId = "agent_id"
        case running
        case turnActive = "turn_active"
        case acpSessionId = "acp_session_id"
        case size, tree, mtime
        case isDir = "is_dir"
        case isRegular = "is_regular"
        case maxDepth = "max_depth"
        case maxEntries = "max_entries"
        case maxDirs = "max_dirs"
        case maxChildren = "max_children"
        case catchup, replay
        case haveSeq = "have_seq"
        case headSeq = "head_seq"
        case startSeq = "start_seq"
        case sessionId = "session_id"
        case requestId = "request_id"
        case holdsTranscript = "holds_transcript"
        case panes, scrollback
    }

    init(
        op: String, cmd: String? = nil, args: [String]? = nil, cwd: String? = nil,
        env: [String: String]? = nil, bytes: Int64? = nil, path: String? = nil,
        code: Int? = nil, error: String? = nil, line: String? = nil,
        entries: [AcpDirEntry]? = nil, agentId: String? = nil, key: String? = nil, data: String? = nil,
        running: Bool? = nil, turnActive: Bool? = nil, acpSessionId: String? = nil,
        agents: [AgentInstanceInfo]? = nil,
        maxDepth: Int? = nil, maxEntries: Int? = nil, maxDirs: Int? = nil, maxChildren: Int? = nil,
        haveSeq: UInt64? = nil, catchup: Bool? = nil, sessionId: String? = nil,
        holdsTranscript: Bool? = nil
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
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
        self.maxDirs = maxDirs
        self.maxChildren = maxChildren
        self.haveSeq = haveSeq
        self.catchup = catchup
        self.sessionId = sessionId
        self.holdsTranscript = holdsTranscript
    }
}

public enum AcpHostError: Error, Sendable {
    case protocolError(String)
    /// The daemon answered a structure/resize op with structureFailed —
    /// tmux refused the command, or the verb has no faithful v1
    /// translation. Nothing to unwind client-side: there was no optimistic
    /// mutation, and the mirror already shows whatever really happened.
    case structureRefused(String)
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
    /// The relay accepted us but has no daemon socket for this host (HTTP
    /// 503). The Mac is asleep, offline, or its daemon lost the tunnel — the
    /// agents themselves are untouched, so this is "can't reach it", never
    /// "it exited".
    case hostOffline
    /// The relay rejected our device challenge (HTTP 401): this device is no
    /// longer authorized for that Mac, or the clocks drifted past the
    /// signature window. Re-pairing is the fix; retrying is not.
    case deviceNotAuthorized(String)
}

extension AcpHostError: CustomStringConvertible {
    /// Human wording — this is what `String(describing:)` yields when the
    /// error is surfaced in a transcript notice, so it must read cleanly
    /// rather than leak the Swift case name.
    public var description: String {
        switch self {
        case .protocolError(let s): return s
        case .structureRefused(let s): return s
        case .handshakeRejected(let s): return "pairing rejected: \(s)"
        case .hostKeyMismatch:
            return "the Mac's identity key changed since pairing — re-pair this device"
        case .spawnFailed(let s): return s
        case .connectionClosed: return "connection to the Mac closed"
        case .timeout(let s): return s
        case .daemonNotRunning: return "can't reach the Mac's agent host (bento-daemon)"
        case .hostOffline: return "the Mac is offline"
        case .deviceNotAuthorized(let s):
            return "this device isn't authorized for that Mac anymore (\(s)) — re-pair it"
        }
    }
}
