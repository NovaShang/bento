import CryptoKit
import ACPKit
import Foundation

/// Everything needed to reach one paired Mac over the relay.
public struct AcpRelayConfig: Sendable {
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
    var isTransientChatter: Bool {
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

/// ACPTransport over an acphost stream. Sealed mode (relay) runs the signed
/// X25519 handshake; plaintext mode (local unix socket) skips crypto —
/// trust is the 0600 socket. Also carries the control surface: spawn,
/// attach/detach (persistence!), list, listdir, kill.
public final class AcpHostTransport: NSObject, ACPTransport, @unchecked Sendable {
    public enum Mode: Sendable {
        case sealed(AcpRelayConfig)
        case plaintext
    }

    public let incoming: AsyncThrowingStream<Data, Error>

    private let incomingCont: AsyncThrowingStream<Data, Error>.Continuation
    private let link: any AcpByteLink
    private let mode: Mode
    private let lock = NSLock()

    private var receiveTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?

    private var unitBuf = AcpUnitBuffer()
    private var sealOut: AcpBoxer?
    private var sealIn: AcpBoxer?
    private var established = false
    private var closed = false

    private var welcomeCont: CheckedContinuation<AcpWelcome, Error>?
    private var attachCont: CheckedContinuation<AttachInfo, Error>?
    private var listCont: CheckedContinuation<[AgentInstanceInfo], Error>?
    private var dirCont: CheckedContinuation<(String, [AcpDirEntry]), Error>?
    /// getState waiters, FIFO per key. Concurrent getStates (the workspace
    /// mirror pulls several keys at once) used to share ONE slot matched by
    /// arrival order — racing calls delivered the wrong blob to the wrong
    /// caller. The daemon answers in request order and echoes the key, so
    /// matching key-first-in-first-out is exact.
    private struct StateWaiter {
        let token: UUID
        let key: String
        let cont: CheckedContinuation<Data?, Error>
    }
    private var stateWaiters: [StateWaiter] = []
    private var fileCont: CheckedContinuation<String, Error>?
    /// Accumulates chunked `filedata` base64 across control messages.
    private var filePartial = ""
    /// File-preview (bento-file) waiters. Callers serialize (RelayFileSource is
    /// an actor), so a single slot per op is safe.
    private var statCont: CheckedContinuation<AcpFileStat, Error>?
    private var treeCont: CheckedContinuation<(String, [AcpTreeEntry]), Error>?
    private var bytesCont: CheckedContinuation<Data, Error>?

    /// Scrollback-cursor scanner state (lock-guarded): the head bytes of the
    /// in-progress stdio line (enough for a `{"_seq":<n>,` prefix) and
    /// whether we're past them mid-line. The daemon stamps `_seq` FIRST
    /// (sorted-key marshal), so the prefix decides in ≤32 bytes.
    private var seqLineHead = Data()
    private var seqMidLine = false
    private var _lastUpdateSeq: UInt64 = 0

    /// Highest scrollback stamp delivered on this stream — the catch-up
    /// cursor a reconnect hands to `attach(agentID:haveSeq:)`. Delivered ⇒
    /// will be processed (in-process pipeline survives a dropped link), so
    /// reading it at reconnect time can't skip lines.
    public var lastUpdateSeq: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _lastUpdateSeq
    }

    private static let seqPrefix = Data(#"{"_seq":"#.utf8)

    private func scanSeqStamps(_ payload: some Sequence<UInt8>) {
        lock.lock()
        defer { lock.unlock() }
        for byte in payload {
            if byte == 0x0A {
                if let seq = Self.parseSeqPrefix(seqLineHead), seq > _lastUpdateSeq {
                    _lastUpdateSeq = seq
                }
                seqLineHead.removeAll(keepingCapacity: true)
                seqMidLine = false
            } else if !seqMidLine {
                seqLineHead.append(byte)
                if seqLineHead.count >= 32 { seqMidLine = true }
            }
        }
    }

    private static func parseSeqPrefix(_ head: Data) -> UInt64? {
        guard head.count > seqPrefix.count, head.starts(with: seqPrefix) else { return nil }
        var value: UInt64 = 0
        var sawDigit = false
        for byte in head.dropFirst(seqPrefix.count) {
            guard byte >= 0x30, byte <= 0x39 else { break }
            value = value &* 10 &+ UInt64(byte - 0x30)
            sawDigit = true
        }
        return sawDigit ? value : nil
    }

    /// Plain (type-prefixed) units queued for the single sender task —
    /// sealing must be strict FIFO (counter nonces).
    private var sendCont: AsyncStream<Data>.Continuation?

    private var _onEvent: (@Sendable (AcpHostEvent) -> Void)?

    /// Host events that arrived before a handler was bound, flushed in
    /// arrival order on the first assignment.
    ///
    /// The daemon starts delivering the instant it answers `attach`, but a
    /// caller can only bind `onEvent` once it HOLDS the transport — which is
    /// after that round-trip (AgentSessionViewModel binds in
    /// `bootstrapAttached`, several awaits later, on a main actor busy
    /// rebuilding every pane at app launch). A `turnDone` landing in that
    /// window used to vanish into `onEvent?` with nothing to re-send it: the
    /// attach control had already reported `turn_active: true`, and the
    /// prompt response belongs to the connection that issued it, so the pane
    /// showed a turn that had long since ended — typing at it only queued
    /// messages the agent never saw.
    private var pendingEvents: [AcpHostEvent] = []

    /// Bound on that buffer — it only grows if a handler is never bound at
    /// all. Chatter (stderr, statekv pokes) is evicted first so log noise
    /// can't push a turn-end or an exit out of a full buffer.
    static let maxPendingEvents = 256

    public var onEvent: (@Sendable (AcpHostEvent) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onEvent
        }
        set {
            lock.lock()
            _onEvent = newValue
            let drained = pendingEvents
            pendingEvents.removeAll()
            lock.unlock()
            // Outside the lock: the handler hops to the main actor and may
            // call back into the transport.
            guard let newValue else { return }
            for event in drained { newValue(event) }
        }
    }

    /// Deliver a host event, or hold it until a handler exists.
    private func emit(_ event: AcpHostEvent) {
        lock.lock()
        if let handler = _onEvent {
            lock.unlock()
            handler(event)
            return
        }
        if pendingEvents.count >= Self.maxPendingEvents {
            let victim = pendingEvents.firstIndex(where: \.isTransientChatter) ?? 0
            pendingEvents.remove(at: victim)
        }
        pendingEvents.append(event)
        lock.unlock()
    }

    public init(link: any AcpByteLink, mode: Mode) {
        self.link = link
        self.mode = mode
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { cont = $0 }
        incomingCont = cont
        super.init()
    }

    // MARK: - Connection

    public func connect() async throws {
        try await link.open()
        startReceiveLoop()

        switch mode {
        case .plaintext:
            lock.lock()
            established = true
            lock.unlock()
        case .sealed(let config):
            try await handshake(config: config)
        }
        startSenderLoop()
    }

    private func handshake(config: AcpRelayConfig) async throws {
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: config.devicePrivateKey)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephB64 = eph.publicKey.rawRepresentation.base64EncodedString()
        let ts = Int64(Date().timeIntervalSince1970)
        let helloMsg = AcpHostProtocol.helloSigMessage(
            daemonID: config.daemonID, deviceID: config.deviceID, ts: ts, ephPubB64: ephB64)
        let sig = try signer.signature(for: helloMsg)
        let hello = AcpHello(
            v: AcpHostProtocol.version, deviceId: config.deviceID, ts: ts,
            ephPub: ephB64, sig: sig.base64EncodedString())
        try await link.send(acpPrefixUnit(try JSONEncoder().encode(hello)))

        let welcome: AcpWelcome = try await withTimeout(seconds: 15, label: "handshake") {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.welcomeCont = cont
                    self.lock.unlock()
                }
            } onCancel: {
                self.takeWelcome()?.resume(throwing: CancellationError())
            }
        }
        if let error = welcome.error, !error.isEmpty {
            throw AcpHostError.handshakeRejected(error)
        }
        guard let hostPubB64 = welcome.hostPub, let hostPub = Data(base64Encoded: hostPubB64),
            let hostEphB64 = welcome.ephPub, let welcomeSig = welcome.sig,
            let sigData = Data(base64Encoded: welcomeSig)
        else {
            throw AcpHostError.protocolError("malformed welcome")
        }

        let presented = AcpHostProtocol.sshFingerprint(rawEd25519PublicKey: hostPub)
        guard presented == config.hostKeyFingerprint else {
            throw AcpHostError.hostKeyMismatch(pinned: config.hostKeyFingerprint, presented: presented)
        }
        let welcomeMsg = AcpHostProtocol.welcomeSigMessage(
            daemonID: config.daemonID, deviceID: config.deviceID, ts: ts,
            clientEphB64: ephB64, hostEphB64: hostEphB64)
        let hostKey = try Curve25519.Signing.PublicKey(rawRepresentation: hostPub)
        guard hostKey.isValidSignature(sigData, for: welcomeMsg) else {
            throw AcpHostError.protocolError("invalid host signature")
        }

        guard let hostEph = Data(base64Encoded: hostEphB64) else {
            throw AcpHostError.protocolError("bad host ephemeral key")
        }
        let shared = try eph.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostEph))
        let keys = AcpHostProtocol.deriveKeys(
            shared: shared, daemonID: config.daemonID, deviceID: config.deviceID)

        lock.lock()
        sealOut = AcpBoxer(key: keys.c2s)
        sealIn = AcpBoxer(key: keys.s2c)
        established = true
        lock.unlock()
    }

    // MARK: - Control operations

    /// Spawn a persistent agent on the host; resolves with its id.
    ///
    /// Naming `conversationID` (the ACP session this process is being
    /// started for) makes the spawn an ENSURE: the daemon hands back the
    /// agent already running that conversation instead of starting a rival
    /// on the same history, and serves the backlog from its durable log —
    /// so pass the catch-up cursor too. Older daemons ignore both fields
    /// and spawn unconditionally, which is the previous behavior.
    public func spawn(
        command: String, args: [String], cwd: String, env: [String: String],
        conversationID: String? = nil, haveSeq: UInt64 = 0,
        holdsTranscript: Bool = false
    ) async throws -> AttachInfo {
        try await awaitAttach(timeoutSeconds: 30, label: "spawn \(command)") {
            self.enqueueControl(AcpControl(
                op: "spawn", cmd: command, args: args, cwd: cwd, env: env,
                haveSeq: haveSeq, catchup: conversationID != nil,
                sessionId: conversationID, holdsTranscript: holdsTranscript))
        }
    }

    /// Attach to an existing agent instance (persistence / handoff).
    /// `haveSeq` is the last scrollback stamp this client processed (0 =
    /// none); the daemon replays the missing tail point-to-point when it
    /// can (see `AttachInfo.replay`). Old daemons ignore the extra fields.
    public func attach(agentID: String, haveSeq: UInt64 = 0,
                       holdsTranscript: Bool = false) async throws -> AttachInfo {
        try await awaitAttach(timeoutSeconds: 10, label: "attach \(agentID)") {
            self.enqueueControl(AcpControl(op: "attach", agentId: agentID,
                                           haveSeq: haveSeq, catchup: true,
                                           holdsTranscript: holdsTranscript))
        }
    }

    private func awaitAttach(
        timeoutSeconds: Double, label: String, fire: @escaping @Sendable () -> Void
    ) async throws -> AttachInfo {
        try await withTimeout(seconds: timeoutSeconds, label: label) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.attachCont = cont
                    self.lock.unlock()
                    fire()
                }
            } onCancel: {
                self.takeAttach()?.resume(throwing: CancellationError())
            }
        }
    }

    public func detach() {
        enqueueControl(AcpControl(op: "detach"))
    }

    /// All agent instances on the host.
    public func listAgents() async throws -> [AgentInstanceInfo] {
        try await withTimeout(seconds: 10, label: "list") {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.listCont = cont
                    self.lock.unlock()
                    self.enqueueControl(AcpControl(op: "list"))
                }
            } onCancel: {
                self.takeList()?.resume(throwing: CancellationError())
            }
        }
    }

    /// Write a daemon statekv value (workspace structure). Fire-and-forget;
    /// the daemon fans statechanged out to other clients. Empty data deletes.
    public func setState(key: String, data: Data) {
        enqueueControl(AcpControl(op: "setstate", key: key,
                                  data: data.isEmpty ? "" : data.base64EncodedString()))
    }

    /// Read a daemon statekv value; nil when unset.
    public func getState(key: String) async throws -> Data? {
        let token = UUID()
        return try await withTimeout(seconds: 10, label: "getstate") {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.stateWaiters.append(StateWaiter(token: token, key: key, cont: cont))
                    self.lock.unlock()
                    self.enqueueControl(AcpControl(op: "getstate", key: key))
                }
            } onCancel: {
                self.removeStateWaiter(token)?.resume(throwing: CancellationError())
            }
        }
    }

    /// Browse a host directory (cwd picker). Empty path = host home.
    public func listDir(_ path: String) async throws -> (path: String, entries: [AcpDirEntry]) {
        let result: (String, [AcpDirEntry]) = try await withTimeout(seconds: 10, label: "listdir") {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.dirCont = cont
                    self.lock.unlock()
                    self.enqueueControl(AcpControl(op: "listdir", path: path))
                }
            } onCancel: {
                self.takeDir()?.resume(throwing: CancellationError())
            }
        }
        return (path: result.0, entries: result.1)
    }

    public func killAgent(id: String? = nil) {
        enqueueControl(AcpControl(op: "kill", agentId: id))
    }

    /// Read a text file on the host (preview; ≤2 MiB, UTF-8 only).
    public func readFile(_ path: String) async throws -> String {
        try await withTimeout(seconds: 15, label: "readfile") {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.fileCont = cont
                    self.lock.unlock()
                    self.enqueueControl(AcpControl(op: "readfile", path: path))
                }
            } onCancel: {
                self.takeFile()?.resume(throwing: CancellationError())
            }
        }
    }

    /// Resolve + stat a path on the host (bento-file). The daemon resolves
    /// `~`/relative against `cwd` and follows symlinks.
    public func stat(path: String, cwd: String?) async throws -> AcpFileStat {
        try await withTimeout(seconds: 15, label: "stat") {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.statCont = cont
                    self.lock.unlock()
                    self.enqueueControl(AcpControl(op: "stat", cwd: cwd, path: path))
                }
            } onCancel: {
                self.takeStat()?.resume(throwing: CancellationError())
            }
        }
    }

    /// Read up to `maxBytes` raw bytes from the head of a host file (images /
    /// binaries; the daemon caps at 20 MiB). `path` is an already-resolved
    /// absolute path.
    public func readBytes(path: String, maxBytes: Int) async throws -> Data {
        try await withTimeout(seconds: 20, label: "readbytes") {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.bytesCont = cont
                    self.lock.unlock()
                    self.enqueueControl(AcpControl(op: "readbytes", bytes: Int64(maxBytes), path: path))
                }
            } onCancel: {
                self.takeBytes()?.resume(throwing: CancellationError())
            }
        }
    }

    /// Bounded recursive listing under `root` (the file-tree browser + path
    /// resolver index). Server-side BFS honoring the bounds.
    public func listTree(root: String, cwd: String?, maxDepth: Int, maxEntries: Int,
                         maxDirs: Int, maxChildren: Int) async throws -> (root: String, entries: [AcpTreeEntry]) {
        let result: (String, [AcpTreeEntry]) = try await withTimeout(seconds: 20, label: "listtree") {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.treeCont = cont
                    self.lock.unlock()
                    self.enqueueControl(AcpControl(
                        op: "listtree", cwd: cwd, path: root,
                        maxDepth: maxDepth, maxEntries: maxEntries,
                        maxDirs: maxDirs, maxChildren: maxChildren))
                }
            } onCancel: {
                self.takeTree()?.resume(throwing: CancellationError())
            }
        }
        return (root: result.0, entries: result.1)
    }

    private func takeFile() -> CheckedContinuation<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = fileCont
        fileCont = nil
        return cont
    }

    private func takeStat() -> CheckedContinuation<AcpFileStat, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = statCont
        statCont = nil
        return cont
    }

    private func takeTree() -> CheckedContinuation<(String, [AcpTreeEntry]), Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = treeCont
        treeCont = nil
        return cont
    }

    private func takeBytes() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = bytesCont
        bytesCont = nil
        return cont
    }

    private func takeWelcome() -> CheckedContinuation<AcpWelcome, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = welcomeCont
        welcomeCont = nil
        return cont
    }

    private func takeAttach() -> CheckedContinuation<AttachInfo, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = attachCont
        attachCont = nil
        return cont
    }

    private func takeList() -> CheckedContinuation<[AgentInstanceInfo], Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = listCont
        listCont = nil
        return cont
    }

    private func popStateWaiter(key: String?) -> CheckedContinuation<Data?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let idx = key.flatMap { k in stateWaiters.firstIndex { $0.key == k } } ?? stateWaiters.indices.first
        guard let idx else { return nil }
        return stateWaiters.remove(at: idx).cont
    }

    private func removeStateWaiter(_ token: UUID) -> CheckedContinuation<Data?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = stateWaiters.firstIndex(where: { $0.token == token }) else { return nil }
        return stateWaiters.remove(at: idx).cont
    }

    private func drainStateWaiters() -> [CheckedContinuation<Data?, Error>] {
        lock.lock()
        defer { lock.unlock() }
        let conts = stateWaiters.map(\.cont)
        stateWaiters.removeAll()
        return conts
    }

    private func takeDir() -> CheckedContinuation<(String, [AcpDirEntry]), Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = dirCont
        dirCont = nil
        return cont
    }

    // MARK: - ACPTransport

    public func send(_ data: Data) async throws {
        lock.lock()
        defer { lock.unlock() }
        guard established, !closed, let cont = sendCont else { throw ACPError.transportClosed }
        // Chunk under the receiver's MaxUnit cap (a big prompt — say an
        // image content block — must not tear the transport). The daemon
        // reassembles its stdio byte stream on newlines, so the split is
        // invisible; holding the lock keeps one line's chunks contiguous
        // against concurrent senders.
        var off = data.startIndex
        repeat {
            let end = data.index(off, offsetBy: AcpHostProtocol.stdioChunk,
                                 limitedBy: data.endIndex) ?? data.endIndex
            var unit = Data([AcpHostProtocol.unitTypeStdio])
            unit.append(data[off..<end])
            cont.yield(unit)
            off = end
        } while off < data.endIndex
    }

    public func close() {
        finish(error: nil)
    }

    // MARK: - Loops

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let link = self?.link else { return }
            do {
                for try await chunk in link.incoming {
                    self?.handleChunk(chunk)
                }
                self?.finish(error: AcpHostError.connectionClosed)
            } catch {
                self?.finish(error: AcpHostError.connectionClosed)
            }
        }
    }

    private func startSenderLoop() {
        let stream = AsyncStream<Data> { cont in
            lock.lock()
            sendCont = cont
            lock.unlock()
        }
        let isPlaintext: Bool = {
            if case .plaintext = mode { return true }
            return false
        }()
        senderTask = Task { [weak self] in
            for await plainUnit in stream {
                guard let self else { return }
                var body: Data?
                if isPlaintext {
                    body = plainUnit
                } else {
                    self.lock.lock()
                    if var boxer = self.sealOut {
                        body = try? boxer.seal(plainUnit)
                        self.sealOut = boxer
                    }
                    self.lock.unlock()
                }
                guard let body else { continue }
                do {
                    try await self.link.send(acpPrefixUnit(body))
                } catch {
                    self.finish(error: AcpHostError.connectionClosed)
                    return
                }
            }
        }
    }

    // MARK: - Inbound

    private func handleChunk(_ data: Data) {
        let units: [Data]
        lock.lock()
        do {
            units = try unitBuf.append(data)
        } catch {
            lock.unlock()
            finish(error: error)
            return
        }
        lock.unlock()
        // Stdio units that arrived together are handed up as ONE chunk: the
        // daemon writes one unit per JSON-RPC line, so yielding per unit made
        // every line its own read → its own decode hop → its own UI
        // invalidation. A catch-up replay is thousands of lines in a handful
        // of socket reads; batching them is the difference between one
        // invalidation per read and one per line. Flushed before any control
        // unit so ordering against turnDone/exit is unchanged.
        var stdio = Data()
        for unit in units { handleUnit(unit, stdio: &stdio) }
        flushStdio(&stdio)
    }

    /// Hand the accumulated stdio bytes up and credit the daemon for them.
    private func flushStdio(_ stdio: inout Data) {
        guard !stdio.isEmpty else { return }
        let payload = stdio
        stdio = Data()
        incomingCont.yield(payload)
        // Auto-credit: keep the daemon's window topped up as we consume.
        enqueueControl(AcpControl(op: "credit", bytes: Int64(payload.count)))
    }

    private func handleUnit(_ unit: Data, stdio: inout Data) {
        lock.lock()
        let isEstablished = established
        lock.unlock()

        if !isEstablished {
            flushStdio(&stdio)
            let welcome = (try? JSONDecoder().decode(AcpWelcome.self, from: unit))
                ?? AcpWelcome(error: "malformed welcome")
            takeWelcome()?.resume(returning: welcome)
            return
        }

        var plain: Data?
        if case .plaintext = mode {
            plain = unit
        } else {
            lock.lock()
            if var boxer = sealIn {
                plain = try? boxer.open(unit)
                sealIn = boxer
            }
            lock.unlock()
        }
        guard let plain, let type = plain.first else {
            flushStdio(&stdio)
            finish(error: AcpHostError.protocolError("failed to open unit"))
            return
        }
        let payload = plain.dropFirst()

        switch type {
        case AcpHostProtocol.unitTypeStdio:
            scanSeqStamps(payload)
            stdio.append(payload)
        case AcpHostProtocol.unitTypeControl:
            flushStdio(&stdio)
            if let control = try? JSONDecoder().decode(AcpControl.self, from: Data(payload)) {
                handleControl(control)
            }
        default:
            break
        }
    }

    private func handleControl(_ control: AcpControl) {
        switch control.op {
        case "attached":
            takeAttach()?.resume(
                returning: AttachInfo(
                    agentID: control.agentId ?? "",
                    running: control.running ?? true,
                    turnActive: control.turnActive ?? false,
                    acpSessionID: control.acpSessionId,
                    headSeq: control.headSeq ?? 0,
                    startSeq: control.startSeq ?? 0,
                    replay: control.replay ?? false))
        case "attachFailed":
            takeAttach()?.resume(
                throwing: AcpHostError.spawnFailed(control.error ?? "attach failed"))
        case "agents":
            takeList()?.resume(returning: control.agents ?? [])
        case "detached":
            emit(.detachedByAnotherClient)
        case "turnDone":
            emit(.turnFinishedWhileDetached(stopReason: control.line ?? "end_turn"))
        case "turnStarted":
            emit(.turnStartedElsewhere)
        case "requestAnswered":
            emit(.agentRequestAnswered(requestID: control.requestId ?? ""))
        case "exit":
            let message = control.error.flatMap { $0.isEmpty ? nil : $0 }
            if let attach = takeAttach() {
                attach.resume(throwing: AcpHostError.spawnFailed(message ?? "exit \(control.code ?? -1)"))
            } else {
                emit(.agentExited(code: control.code ?? 0, message: message))
                incomingCont.finish()
            }
        case "stderr":
            if let line = control.line { emit(.stderrLine(line)) }
        case "statedata":
            let payload = control.data.flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
            popStateWaiter(key: control.key)?.resume(returning: payload)
        case "statechanged":
            if let key = control.key { emit(.stateChanged(key: key)) }
        case "dirents":
            let cont = takeDir()
            if let error = control.error, !error.isEmpty {
                cont?.resume(throwing: AcpHostError.protocolError(error))
            } else {
                cont?.resume(returning: (control.path ?? "", control.entries ?? []))
            }
        case "statdata":
            let cont = takeStat()
            if let error = control.error, !error.isEmpty {
                cont?.resume(throwing: AcpHostError.protocolError(error))
            } else {
                cont?.resume(returning: AcpFileStat(
                    resolvedPath: control.path ?? "",
                    size: control.size ?? 0,
                    isDir: control.isDir ?? false,
                    isRegular: control.isRegular ?? false,
                    mtime: control.mtime ?? 0))
            }
        case "treedata":
            let cont = takeTree()
            if let error = control.error, !error.isEmpty {
                cont?.resume(throwing: AcpHostError.protocolError(error))
            } else {
                cont?.resume(returning: (control.path ?? "", control.tree ?? []))
            }
        case "filedata":
            // Large files arrive as several chunks (more=true on all but
            // the last); accumulate the base64 text and resolve on the
            // final one. Single-message (old daemon / small file) has no
            // `more` and resolves immediately. `readfile` (text) and
            // `readbytes` (raw) share this response; only one waiter is ever
            // live (callers serialize), and bytes takes priority.
            if let error = control.error, !error.isEmpty {
                filePartial = ""
                takeBytes()?.resume(throwing: AcpHostError.protocolError(error))
                takeFile()?.resume(throwing: AcpHostError.protocolError(error))
            } else if control.more == true {
                filePartial += control.data ?? ""
            } else {
                let b64 = filePartial + (control.data ?? "")
                filePartial = ""
                let data = Data(base64Encoded: b64)
                if let bytesCont = takeBytes() {
                    if let data {
                        bytesCont.resume(returning: data)
                    } else {
                        bytesCont.resume(throwing: AcpHostError.protocolError("bad filedata"))
                    }
                } else if let fileCont = takeFile() {
                    if let data, let text = String(data: data, encoding: .utf8) {
                        fileCont.resume(returning: text)
                    } else {
                        fileCont.resume(throwing: AcpHostError.protocolError("bad filedata"))
                    }
                }
            }
        default:
            break
        }
    }

    private func enqueueControl(_ control: AcpControl) {
        guard let body = try? JSONEncoder().encode(control) else { return }
        lock.lock()
        let cont = sendCont
        lock.unlock()
        var unit = Data([AcpHostProtocol.unitTypeControl])
        unit.append(body)
        cont?.yield(unit)
    }

    private func finish(error: Error?) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let sender = sendCont
        sendCont = nil
        lock.unlock()

        let failure = error ?? AcpHostError.connectionClosed
        takeWelcome()?.resume(throwing: failure)
        takeAttach()?.resume(throwing: failure)
        takeList()?.resume(throwing: failure)
        takeDir()?.resume(throwing: failure)
        for cont in drainStateWaiters() { cont.resume(throwing: failure) }
        takeFile()?.resume(throwing: failure)
        takeStat()?.resume(throwing: failure)
        takeTree()?.resume(throwing: failure)
        takeBytes()?.resume(throwing: failure)
        sender?.finish()
        if let error {
            incomingCont.finish(throwing: error)
        } else {
            incomingCont.finish()
        }
        receiveTask?.cancel()
        link.close()
    }
}

// MARK: - WebSocket link (relay path)

public final class WebSocketByteLink: AcpByteLink, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>

    private let incomingCont: AsyncThrowingStream<Data, Error>.Continuation
    private let makeURL: @Sendable () throws -> URL
    private let lock = NSLock()
    private var session: URLSession?
    private var ws: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var closed = false

    public init(makeURL: @escaping @Sendable () throws -> URL) {
        self.makeURL = makeURL
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { cont = $0 }
        incomingCont = cont
    }

    public func open() async throws {
        let url = try makeURL()
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        lock.lock()
        self.session = session
        self.ws = task
        lock.unlock()
        task.resume()

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let task = self?.currentWS() else { return }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .data(let d): self?.incomingCont.yield(d)
                    case .string(let s): self?.incomingCont.yield(Data(s.utf8))
                    @unknown default: break
                    }
                } catch {
                    self?.incomingCont.finish(
                        throwing: Self.upgradeError(task: task, fallback: error))
                    return
                }
            }
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                self?.currentWS()?.sendPing { _ in }
            }
        }
    }

    private func currentWS() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return ws
    }

    /// Recover the relay's actual verdict from a failed upgrade.
    ///
    /// URLSession collapses EVERY non-101 response into the same opaque
    /// `NSURLErrorBadServerResponse` ("There was a bad response from the
    /// server"), and that NSError's description embeds the full signed tunnel
    /// URL — device pubkey and signature included. Unmapped, that blob is what
    /// reached the transcript, and three completely different situations —
    /// the Mac being unreachable, this device no longer being authorized, and
    /// the agent genuinely exiting — all rendered as "Agent exited". The
    /// status code is sitting on the task's response; read it.
    private static func upgradeError(task: URLSessionWebSocketTask, fallback: Error) -> Error {
        guard let http = task.response as? HTTPURLResponse else { return fallback }
        switch http.statusCode {
        case 503:
            return AcpHostError.hostOffline
        case 401, 403:
            return AcpHostError.deviceNotAuthorized("HTTP \(http.statusCode)")
        case 101, 200..<300:
            // A clean upgrade that died later — the real error is the read's.
            return fallback
        default:
            return AcpHostError.protocolError(
                "the relay refused the tunnel (HTTP \(http.statusCode))")
        }
    }

    public func send(_ data: Data) async throws {
        guard let ws = currentWS() else { throw AcpHostError.connectionClosed }
        try await ws.send(.data(data))
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        receiveTask?.cancel()
        pingTask?.cancel()
        ws?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        incomingCont.finish()
    }
}

// MARK: - Factory

public enum AcpHostTransportFactory {
    /// Relay path: WSS tunnel + sealed handshake.
    public static func relay(config: AcpRelayConfig) -> AcpHostTransport {
        let link = WebSocketByteLink {
            try tunnelURL(config: config)
        }
        return AcpHostTransport(link: link, mode: .sealed(config))
    }

    static func tunnelURL(config: AcpRelayConfig) throws -> URL {
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: config.devicePrivateKey)
        guard var c = URLComponents(string: config.relayBaseURL) else {
            throw AcpHostError.protocolError("bad relay URL")
        }
        if c.scheme == "https" { c.scheme = "wss" }
        if c.scheme == "http" { c.scheme = "ws" }
        c.path = "/v1/tunnel"
        let ts = Int(Date().timeIntervalSince1970)
        let msg = "bento-device-attach:\(config.daemonID):\(config.deviceID):\(ts)"
        let sig = try signer.signature(for: Data(msg.utf8))
        func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        c.queryItems = [
            URLQueryItem(name: "daemon_id", value: config.daemonID),
            URLQueryItem(name: "device_id", value: config.deviceID),
            URLQueryItem(name: "ts", value: String(ts)),
            URLQueryItem(name: "pubkey", value: b64url(signer.publicKey.rawRepresentation)),
            URLQueryItem(name: "sig", value: b64url(sig)),
        ]
        guard let url = c.url else { throw AcpHostError.protocolError("bad tunnel URL") }
        return url
    }

    #if os(macOS)
    /// Local path: plaintext units over the daemon's unix socket.
    public static func local(socketPath: String) -> AcpHostTransport {
        AcpHostTransport(link: UnixSocketByteLink(path: socketPath), mode: .plaintext)
    }
    #endif
}

/// Runs an async operation with a wall-clock timeout.
func withTimeout<T: Sendable>(
    seconds: Double, label: String, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AcpHostError.timeout(label)
        }
        guard let result = try await group.next() else {
            throw AcpHostError.timeout(label)
        }
        group.cancelAll()
        return result
    }
}
