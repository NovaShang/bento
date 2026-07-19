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
    case stderrLine(String)
    /// Another client wrote the daemon statekv key — re-pull it.
    case stateChanged(key: String)
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
    private var stateCont: CheckedContinuation<Data?, Error>?
    private var fileCont: CheckedContinuation<String, Error>?

    /// Plain (type-prefixed) units queued for the single sender task —
    /// sealing must be strict FIFO (counter nonces).
    private var sendCont: AsyncStream<Data>.Continuation?

    public var onEvent: (@Sendable (AcpHostEvent) -> Void)?

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

    /// Spawn a new persistent agent on the host; resolves with its id.
    public func spawn(
        command: String, args: [String], cwd: String, env: [String: String]
    ) async throws -> AttachInfo {
        try await awaitAttach(timeoutSeconds: 30, label: "spawn \(command)") {
            self.enqueueControl(AcpControl(op: "spawn", cmd: command, args: args, cwd: cwd, env: env))
        }
    }

    /// Attach to an existing agent instance (persistence / handoff).
    public func attach(agentID: String) async throws -> AttachInfo {
        try await awaitAttach(timeoutSeconds: 10, label: "attach \(agentID)") {
            self.enqueueControl(AcpControl(op: "attach", agentId: agentID))
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
        try await withTimeout(seconds: 10, label: "getstate") {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.stateCont = cont
                    self.lock.unlock()
                    self.enqueueControl(AcpControl(op: "getstate", key: key))
                }
            } onCancel: {
                self.takeState()?.resume(throwing: CancellationError())
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

    private func takeFile() -> CheckedContinuation<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = fileCont
        fileCont = nil
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

    private func takeState() -> CheckedContinuation<Data?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = stateCont
        stateCont = nil
        return cont
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
        let ok = established && !closed
        let cont = sendCont
        lock.unlock()
        guard ok, let cont else { throw ACPError.transportClosed }
        var unit = Data([AcpHostProtocol.unitTypeStdio])
        unit.append(data)
        cont.yield(unit)
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
        for unit in units { handleUnit(unit) }
    }

    private func handleUnit(_ unit: Data) {
        lock.lock()
        let isEstablished = established
        lock.unlock()

        if !isEstablished {
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
            finish(error: AcpHostError.protocolError("failed to open unit"))
            return
        }
        let payload = plain.dropFirst()

        switch type {
        case AcpHostProtocol.unitTypeStdio:
            incomingCont.yield(Data(payload))
            // Auto-credit: keep the daemon's window topped up as we consume.
            enqueueControl(AcpControl(op: "credit", bytes: Int64(payload.count)))
        case AcpHostProtocol.unitTypeControl:
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
                    acpSessionID: control.acpSessionId))
        case "attachFailed":
            takeAttach()?.resume(
                throwing: AcpHostError.spawnFailed(control.error ?? "attach failed"))
        case "agents":
            takeList()?.resume(returning: control.agents ?? [])
        case "detached":
            onEvent?(.detachedByAnotherClient)
        case "turnDone":
            onEvent?(.turnFinishedWhileDetached(stopReason: control.line ?? "end_turn"))
        case "exit":
            let message = control.error.flatMap { $0.isEmpty ? nil : $0 }
            if let attach = takeAttach() {
                attach.resume(throwing: AcpHostError.spawnFailed(message ?? "exit \(control.code ?? -1)"))
            } else {
                onEvent?(.agentExited(code: control.code ?? 0, message: message))
                incomingCont.finish()
            }
        case "stderr":
            if let line = control.line { onEvent?(.stderrLine(line)) }
        case "statedata":
            let payload = control.data.flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
            takeState()?.resume(returning: payload)
        case "statechanged":
            if let key = control.key { onEvent?(.stateChanged(key: key)) }
        case "dirents":
            let cont = takeDir()
            if let error = control.error, !error.isEmpty {
                cont?.resume(throwing: AcpHostError.protocolError(error))
            } else {
                cont?.resume(returning: (control.path ?? "", control.entries ?? []))
            }
        case "filedata":
            let cont = takeFile()
            if let error = control.error, !error.isEmpty {
                cont?.resume(throwing: AcpHostError.protocolError(error))
            } else if let b64 = control.data, let data = Data(base64Encoded: b64),
                let text = String(data: data, encoding: .utf8)
            {
                cont?.resume(returning: text)
            } else {
                cont?.resume(throwing: AcpHostError.protocolError("bad filedata"))
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
        takeState()?.resume(throwing: failure)
        takeFile()?.resume(throwing: failure)
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
                    self?.incomingCont.finish(throwing: error)
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
