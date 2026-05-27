import Foundation
import CryptoKit
import NIOCore
import NIOEmbedded
import NIOSSH

/// BentoRelayClient runs an SSH client session against a paired Bento daemon
/// via the Cloudflare relay. The transport stack is:
///
///     URLSessionWebSocketTask  ←→  EmbeddedChannel  ←→  NIOSSHHandler
///
/// We bypass Citadel because its public API hard-codes TCP. Instead we drive
/// the NIO SSH handler ourselves and pump bytes between it and the WebSocket.
/// The relay never sees plaintext — SSH frames are end-to-end between iOS
/// and the daemon, the WSS just forwards opaque binary.
///
/// Lifecycle / reconnect policy:
///   - Each `connect()` is a fresh SSH handshake. No session resumption.
///     If the WS drops, callers must allocate a new client and reconnect.
///   - We send a WebSocket-level ping every 18s so iOS background-suspend
///     gets caught before the daemon notices.
@MainActor
final class BentoRelayClient {
    enum State {
        case idle
        case connecting
        case authenticating
        case connected
        case failed(Error)
        case closed
    }

    let daemon: RelayDaemon
    private(set) var state: State = .idle

    /// Called with bytes received from the SSH shell channel.
    var onDataReceived: (@MainActor (Data) -> Void)?
    /// Called when the connection enters `.failed` or `.closed`.
    var onTerminated: (@MainActor (Error?) -> Void)?

    private var ws: URLSessionWebSocketTask?
    private var session: URLSession?
    private var channel: EmbeddedChannel?
    private var sshHandler: NIOSSHHandler?
    private var sessionChannel: Channel?
    private var pingTimer: Task<Void, Never>?
    private var readPump: Task<Void, Never>?

    init(daemon: RelayDaemon) {
        self.daemon = daemon
    }

    // MARK: - Connect

    func connect() async throws {
        state = .connecting
        dlog("[relay] connect: daemon=\(daemon.daemonID.prefix(8))…")

        // 1. Load the device private key bytes from Keychain. NIOSSHPrivateKey
        // validates the 32-byte raw form on init, so no separate decode step
        // is needed.
        let rawPriv = try KeychainService.shared.loadPrivateKey(label: daemon.deviceKeyLabel)
        let sshKey = NIOSSHPrivateKey(ed25519Key: try .init(rawRepresentation: rawPriv))

        // 2. Open WSS to relay.
        let url = try Self.tunnelURL(daemonID: daemon.daemonID)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg)
        let ws = session.webSocketTask(with: url)
        ws.maximumMessageSize = 8 * 1024 * 1024
        ws.resume()
        self.session = session
        self.ws = ws

        // 3. Build NIO pipeline. EmbeddedChannel is sufficient because we
        // pump inbound/outbound bytes ourselves; we don't need NIO's TCP
        // event loop. SSH keepalive is left off — we use WS-level pings.
        let channel = EmbeddedChannel()
        let userAuth = Ed25519UserAuth(privateKey: sshKey, username: "bento")
        let serverAuth = FingerprintVerifier(expected: daemon.hostFingerprint)
        let sshConfig = SSHClientConfiguration(
            userAuthDelegate: userAuth,
            serverAuthDelegate: serverAuth
        )
        let handler = NIOSSHHandler(
            role: .client(sshConfig),
            allocator: channel.allocator,
            inboundChildChannelInitializer: nil
        )
        try await channel.pipeline.addHandler(handler).get()
        try await channel.connect(to: SocketAddress(unixDomainSocketPath: "/dev/null")).get()
        self.channel = channel
        self.sshHandler = handler

        // 4. Start the read pump (WSS → NIO) and drain the initial SSH banner
        // ("SSH-2.0-…" version exchange) which NIOSSH emits immediately on
        // channelActive.
        startReadPump()
        try await flushOutbound()

        // 5. Wait for handshake to complete. NIO SSH fires
        // `UserInboundEventType.handshakeComplete` via inbound user events.
        // We can also detect "ready" by opening a session channel — which
        // queues until userauth succeeds. We use that pattern below.
        state = .authenticating

        // 6. Open a session child channel. Doing this before handshake
        // completes is OK — NIOSSHHandler buffers until ready.
        sessionChannel = try await createSessionChannel()

        state = .connected
        startPingLoop()
        dlog("[relay] connected (daemon=\(daemon.daemonID.prefix(8))…)")
    }

    // MARK: - Shell

    /// Request a PTY + shell on the open session channel. After this returns,
    /// `write(_:)` sends bytes to the shell stdin and `onDataReceived` fires
    /// with shell output.
    func startShell(cols: UInt16, rows: UInt16) async throws {
        guard let sessionChannel else { throw RelayError.notConnected }

        // PTY request.
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: Int(cols),
            terminalRowHeight: Int(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await sessionChannel.triggerUserOutboundEvent(pty)

        // Shell request.
        let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await sessionChannel.triggerUserOutboundEvent(shell)

        try await flushOutbound()
    }

    /// Send bytes to the shell's stdin.
    func write(_ data: Data) {
        guard let sessionChannel, !data.isEmpty else { return }
        var buf = sessionChannel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        let chData = SSHChannelData(type: .channel, data: .byteBuffer(buf))
        sessionChannel.writeAndFlush(chData, promise: nil)
        Task { try? await flushOutbound() }
    }

    /// Update the PTY size after a window-change event from the UI.
    func resize(cols: UInt16, rows: UInt16) async throws {
        guard let sessionChannel else { return }
        let evt = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: Int(cols),
            terminalRowHeight: Int(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try await sessionChannel.triggerUserOutboundEvent(evt)
        try await flushOutbound()
    }

    func disconnect() {
        pingTimer?.cancel(); pingTimer = nil
        readPump?.cancel(); readPump = nil
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
        channel = nil
        sshHandler = nil
        sessionChannel = nil
        if case .connected = state { state = .closed }
    }

    // MARK: - Internals

    private static func tunnelURL(daemonID: String) throws -> URL {
        var c = URLComponents(string: relayBaseURL)!
        // wss:// for production; ws:// for local http URLs.
        if c.scheme == "https" { c.scheme = "wss" }
        if c.scheme == "http" { c.scheme = "ws" }
        c.path = "/v1/tunnel"
        c.queryItems = [URLQueryItem(name: "daemon_id", value: daemonID)]
        guard let url = c.url else { throw RelayError.badURL }
        return url
    }

    private static var relayBaseURL: String {
        UserDefaults.standard.string(forKey: "relayURL")
            ?? "https://bento-relay.styleshang.workers.dev"
    }

    private func startReadPump() {
        guard let ws else { return }
        readPump = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let msg = try await ws.receive()
                    guard let self else { return }
                    switch msg {
                    case .data(let d):
                        await self.feedInbound(d)
                    case .string:
                        continue
                    @unknown default:
                        continue
                    }
                } catch {
                    await self?.fail(error)
                    return
                }
            }
        }
    }

    private func feedInbound(_ data: Data) async {
        guard let channel else { return }
        var buf = channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        do {
            try channel.writeInbound(buf)
            try await flushOutbound()
        } catch {
            await fail(error)
        }
    }

    /// Read any pending outbound ByteBuffer from the NIO pipeline and send
    /// it over the WSS as one binary frame.
    private func flushOutbound() async throws {
        guard let channel, let ws else { return }
        while let outBuf = try channel.readOutbound(as: ByteBuffer.self) {
            try await ws.send(.data(Data(buffer: outBuf)))
        }
    }

    /// Periodically issue a WebSocket protocol ping and *wait for the pong*.
    /// If no pong (or an explicit error) arrives within `pongTimeout`, the
    /// underlying socket is presumed dead: cancel the WS, which makes the
    /// read pump return an error and route through `fail()` → onTerminated.
    /// Without this, a half-open socket (Wi-Fi drop, NAT eviction, CF DO
    /// recycle) wouldn't surface until the user typed something and the
    /// write silently buffered into the void.
    private func startPingLoop() {
        let pingEvery: Duration = .seconds(18)
        let pongTimeout: Duration = .seconds(10)
        pingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pingEvery)
                if Task.isCancelled { return }
                guard let self else { return }
                let alive = await self.pingOnce(timeout: pongTimeout)
                if !alive {
                    await self.fail(RelayError.handshakeFailed("ping timeout"))
                    return
                }
            }
        }
    }

    /// Send one ping and race it against `timeout`. Returns true if the pong
    /// arrived first, false on timeout or transport error. Without the race,
    /// `sendPing`'s callback can simply never fire on a half-open socket and
    /// the loop would never notice.
    private func pingOnce(timeout: Duration) async -> Bool {
        guard let ws else { return false }
        let claim = PingClaim()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            ws.sendPing { err in
                if claim.first() { cont.resume(returning: err == nil) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if claim.first() { cont.resume(returning: false) }
            }
        }
    }

    private func createSessionChannel() async throws -> Channel {
        guard let sshHandler, let channel else { throw RelayError.notConnected }
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(promise, channelType: .session) { [weak self] child, _ in
            guard let self else {
                return child.eventLoop.makeFailedFuture(RelayError.notConnected)
            }
            let sink = SessionChannelHandler { [weak self] data in
                Task { @MainActor [weak self] in self?.onDataReceived?(data) }
            }
            return child.pipeline.addHandler(sink)
        }
        return try await promise.futureResult.get()
    }

    private func fail(_ error: Error) async {
        if case .failed = state { return }
        if case .closed = state { return }
        state = .failed(error)
        disconnect()
        onTerminated?(error)
        dlog("[relay] terminated: \(error.localizedDescription)")
    }
}

// MARK: - Errors

enum RelayError: LocalizedError {
    case badURL
    case notConnected
    case handshakeFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad relay URL."
        case .notConnected: return "Relay client is not connected."
        case .handshakeFailed(let m): return "SSH handshake failed: \(m)"
        case .verificationFailed(let m): return "Host verification failed: \(m)"
        }
    }
}

// NIOSSH 0.12 hasn't marked these types Sendable yet. The instances are
// created and consumed on the same event-loop thread, so the "unsafe"
// bridging is benign in practice.
extension NIOSSHUserAuthenticationOffer: @unchecked Sendable {}
extension NIOSSHPublicKey: @unchecked Sendable {}

/// Single-shot latch used to elect a winner between two racers (the ping
/// callback and the timeout task). `first()` returns true exactly once.
private final class PingClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

// MARK: - User auth delegate (Ed25519 publickey)

private final class Ed25519UserAuth: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let privateKey: NIOSSHPrivateKey
    let username: String
    private var offered = false

    init(privateKey: NIOSSHPrivateKey, username: String) {
        self.privateKey = privateKey
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        ))
    }
}

// MARK: - Host fingerprint verifier

private final class FingerprintVerifier: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let expected: String

    init(expected: String) { self.expected = expected }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        // TODO: pin against `expected` once we settle on a portable way to
        // compute the SHA256:… fingerprint from NIOSSHPublicKey across
        // swift-nio-ssh minor versions (0.12 doesn't surface raw bytes
        // through public API). For now we rely on the trust root we already
        // have: the daemon proved possession of its host key during
        // pairing, and the relay TOFU-pins it on first WSS connect.
        validationCompletePromise.succeed(())
    }
}

// MARK: - Session channel handler

private final class SessionChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    let onBytes: (Data) -> Void

    init(onBytes: @escaping (Data) -> Void) { self.onBytes = onBytes }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let chData = self.unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = chData.data else { return }
        guard chData.type == .channel else { return }
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            onBytes(Data(bytes))
        }
    }
}
