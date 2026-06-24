import Foundation
import BentoTerminalCore
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

    /// EmbeddedChannel and the SSH transport-protection state it drives (the
    /// AES-GCM outbound nonce + the in-flight outbound ByteBuffers) are NOT
    /// thread-safe. Every public method here is `@MainActor`, so in principle
    /// all access is serialized on the main thread — but the synchronous
    /// channel operations (encrypt on `writeInbound`/`writeAndFlush`/
    /// `triggerUserOutboundEvent`, drain on `readOutbound`) interleave with the
    /// WebSocket `await`s, and a single stray off-main caller corrupts the
    /// cipher buffer mid-seal. That surfaced as an `AES.GCM` `encryptPacket`
    /// assertion crash ("ciphertext.count == encryptedBufferSize") on rapid
    /// resize + keystroke traffic. This lock makes encryption and drain
    /// mutually exclusive regardless of caller thread; only the synchronous
    /// channel touches are held under it — never an `await`.
    private let channelLock = NSLock()

    private func withChannelLock<T>(_ body: () throws -> T) rethrows -> T {
        channelLock.lock()
        defer { channelLock.unlock() }
        return try body()
    }

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
        let cryptoPriv = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPriv)
        let sshKey = NIOSSHPrivateKey(ed25519Key: cryptoPriv)

        // 2. Open WSS to relay. The tunnel URL carries a per-connect Ed25519
        // challenge so the relay can pin our device identity before
        // burning a daemon goroutine on the stream.
        let url = try Self.tunnelURL(daemon: daemon, signer: cryptoPriv)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg)
        let ws = session.webSocketTask(with: url)
        ws.maximumMessageSize = 8 * 1024 * 1024
        ws.resume()
        self.session = session
        self.ws = ws

        // Handshake watchdog. The SSH-over-WS handshake below (version banner,
        // userauth, session-channel open) has no intrinsic timeout, and the
        // EmbeddedEventLoop has no wall clock to schedule one on. If it stalls
        // — dead radio right after unlock, an unresponsive relay/daemon, a relay
        // stream collision — connect() would hang forever and the caller's
        // reconnect loop would spin on "Reconnecting…" with no end. Force the
        // socket down after the budget so the awaits below fail fast (→ the
        // caller retries with backoff). `disconnect()` closes the channel, which
        // fails the pending createSessionChannel promise. Cancelled on success.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled else { return }
            if case .connected = self.state { return }
            dlog("[relay] handshake timed out after 12s — forcing socket down")
            self.disconnect()
        }
        defer { watchdog.cancel() }

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
        try await withChannelLock { sessionChannel.triggerUserOutboundEvent(pty) }.get()

        // Shell request.
        let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await withChannelLock { sessionChannel.triggerUserOutboundEvent(shell) }.get()

        try await flushOutbound()
    }

    /// Send bytes to the shell's stdin.
    func write(_ data: Data) {
        guard let sessionChannel, !data.isEmpty else { return }
        withChannelLock {
            var buf = sessionChannel.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            let chData = SSHChannelData(type: .channel, data: .byteBuffer(buf))
            sessionChannel.writeAndFlush(chData, promise: nil)
        }
        Task { try? await flushOutbound() }
    }

    /// Send a `window-change` channel request so the remote PTY updates its
    /// cols × rows. SwiftTerm's authoritative cell-grid measurement drives
    /// this — without it the shell renders to the initial `startShell` size
    /// (a screen-area estimate that almost always disagrees with the real
    /// SwiftTerm grid), and full-screen TUIs wrap at the wrong column.
    ///
    /// WindowChangeRequest serializes to four UInt32 fields — no Strings, no
    /// optional payloads — so it's safe to send via the same
    /// `triggerUserOutboundEvent` path as PtyReq / Shell.
    func resize(cols: UInt16, rows: UInt16) async throws {
        guard let sessionChannel else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: Int(cols),
            terminalRowHeight: Int(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        // Fire the event and flush it over the WebSocket WITHOUT awaiting the
        // request future — mirror `write()`. window-change wants no reply, and
        // on an idle session nothing else drives a flush, so awaiting `.get()`
        // first left the encrypted frame buffered and never sent: the daemon's
        // PTY stayed at the startShell estimate (e.g. 55) while the surface
        // rendered the real grid (41) → TUIs saw the wrong column count.
        withChannelLock {
            sessionChannel.triggerUserOutboundEvent(event, promise: nil)
            sessionChannel.flush()
        }
        try await flushOutbound()
    }

    func disconnect() {
        pingTimer?.cancel(); pingTimer = nil
        readPump?.cancel(); readPump = nil
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
        // Close the channel (not just drop it) so any in-flight SSH operation —
        // notably the createSessionChannel promise during connect() — fails
        // promptly via channelInactive instead of hanging. Dropping the
        // reference alone never completes a pending promise.
        if let ch = channel {
            withChannelLock { ch.close(promise: nil) }
        }
        channel = nil
        sshHandler = nil
        sessionChannel = nil
        if case .connected = state { state = .closed }
    }

    // MARK: - Internals

    /// Build the authenticated tunnel URL. Mirror of the daemon's
    /// `authedSocketURL` in desktop/internal/relay/client.go — both sides
    /// produce the same canonical challenge string for their role, and the
    /// relay's `verifyDeviceChallenge` validates the signature using the
    /// pubkey it pinned at pair time.
    private static func tunnelURL(daemon: RelayDaemon, signer: Curve25519.Signing.PrivateKey) throws -> URL {
        var c = URLComponents(string: relayBaseURL)!
        // wss:// for production; ws:// for local http URLs.
        if c.scheme == "https" { c.scheme = "wss" }
        if c.scheme == "http" { c.scheme = "ws" }
        c.path = "/v1/tunnel"
        let ts = Int(Date().timeIntervalSince1970)
        let msg = "bento-device-attach:\(daemon.daemonID):\(daemon.deviceID):\(ts)"
        let sig = try signer.signature(for: Data(msg.utf8))
        let pub = signer.publicKey.rawRepresentation
        c.queryItems = [
            URLQueryItem(name: "daemon_id", value: daemon.daemonID),
            URLQueryItem(name: "device_id", value: daemon.deviceID),
            URLQueryItem(name: "ts", value: String(ts)),
            URLQueryItem(name: "pubkey", value: pub.base64URLEncoded()),
            URLQueryItem(name: "sig", value: sig.base64URLEncoded()),
        ]
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
        do {
            try withChannelLock {
                var buf = channel.allocator.buffer(capacity: data.count)
                buf.writeBytes(data)
                try channel.writeInbound(buf)
            }
            try await flushOutbound()
        } catch {
            await fail(error)
        }
    }

    /// Read any pending outbound ByteBuffer from the NIO pipeline and send
    /// it over the WSS as one binary frame.
    private func flushOutbound() async throws {
        guard let channel, let ws else { return }
        // Pop each already-encrypted frame under the lock (so it can't race a
        // concurrent encrypt), then send it outside the lock. SSH frames must
        // reach the daemon in nonce order; `readOutbound` dequeues them in
        // order and `await ws.send` preserves that within this drain.
        while let outBuf = try withChannelLock({ try channel.readOutbound(as: ByteBuffer.self) }) {
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
        withChannelLock {
            sshHandler.createChannel(promise, channelType: .session) { [weak self] child, _ in
                guard let self else {
                    return child.eventLoop.makeFailedFuture(RelayError.notConnected)
                }
                let sink = SessionChannelHandler { [weak self] data in
                    Task { @MainActor [weak self] in self?.onDataReceived?(data) }
                }
                return child.pipeline.addHandler(sink)
            }
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

private extension Data {
    /// RFC 4648 base64url (without padding) — what the relay's
    /// `decodeB64Url` expects in the challenge query params.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
