// iOS only, on purpose. macOS reaches a remote host by spawning the system
// `ssh` through `LocalPtyTransport` — it inherits ~/.ssh/config, the ProxyJump
// chain and the running agent, none of which an in-process client gets, and it
// keeps Bento Term's macOS floor at 14 (Citadel's `withPTY` wants 15). A phone
// has no binary to spawn and cannot fork, so there it has to be Citadel.
#if os(iOS)
import BentoFilePreviewKit
import BentoFoundation
import Citadel
import Crypto
import Foundation
import NIO
import NIOSSH
import os

/// The connection-state type is `TerminalConnectionState` (shared with the
/// pty transport). Kept as a typealias so existing call sites
/// (`SSHConnectionState`) are unchanged.
public typealias SSHConnectionState = TerminalConnectionState

public enum SSHError: LocalizedError {
    case notConnected
    case invalidKeyFormat

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server."
        case .invalidKeyFormat: return "Invalid SSH key format."
        }
    }
}

/// Wrapper to make TTYStdinWriter usable across concurrency boundaries.
/// TTYStdinWriter is a struct containing a NIO Channel, which is thread-safe.
struct SendableStdinWriter: @unchecked Sendable {
    let writer: TTYStdinWriter
}

/// Thread-safe mutable state for SSHService
private struct SSHMutableState: Sendable {
    var state: SSHConnectionState = .disconnected
    var stdinWriter: SendableStdinWriter?
}

/// Manages an SSH connection and interactive shell session over Citadel/NIOSSH.
///
/// This is the iOS side of the story. macOS reaches a remote host by spawning
/// the system `ssh` through `LocalPtyTransport` instead — that inherits the
/// user's `~/.ssh/config`, ProxyJump chain and running agent for free, none of
/// which an in-process client gets. A phone has no `ssh` binary and cannot
/// fork, so there it has to be this.
public final class SSHService: @unchecked Sendable, TerminalTransport {
    private let mutableState = OSAllocatedUnfairLock(initialState: SSHMutableState())
    private var client: SSHClient?
    private var sessionTask: Task<Void, Never>?

    public init() {}

    public var state: SSHConnectionState {
        mutableState.withLock { $0.state }
    }

    /// Called on each chunk of terminal output
    public var onDataReceived: (@Sendable (Data) -> Void)?
    public var onStateChanged: (@Sendable (SSHConnectionState) -> Void)?

    /// Publish a connection-state change: store it, then notify the observer.
    private func transition(to s: SSHConnectionState) {
        mutableState.withLock { $0.state = s }
        onStateChanged?(s)
    }

    // MARK: - Connect

    public func connect(host: BentoFoundation.Host) async {
        transition(to: .connecting)

        // `Host.transport` is shared with product A, whose pairing flow does
        // build `.relay` hosts. Bento Term never does — and refusing loudly
        // beats dialing hostname:port at something that was never a TCP host.
        guard case .directTCP = host.transport else {
            transition(to: .failed("This host is not reachable over SSH."))
            return
        }

        do {
            let authentication: SSHAuthenticationMethod

            switch host.authMethod {
            case .password:
                let password = try KeychainService.shared.loadPassword(for: host.id.uuidString)
                authentication = .passwordBased(username: host.username, password: password)
            case .privateKey(let keyLabel):
                let keyData = try KeychainService.shared.loadPrivateKey(label: keyLabel)
                let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
                authentication = .ed25519(username: host.username, privateKey: ed25519Key)
            }

            let sshClient = try await SSHClient.connect(
                host: host.hostname,
                port: Int(host.port),
                authenticationMethod: authentication,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )

            self.client = sshClient
            mutableState.withLock { $0.state = .connected }
            dlog("SSH connected successfully")
            Task { @MainActor in TelemetryService.shared.record(.sshDirectConnected) }

            // Identify this client so the disconnect callback can tell whether
            // it's still the active client. Otherwise an old client's delayed
            // onDisconnect (after the user popped + we reconnected) would
            // clobber the new client's .connected state, leaving the UI
            // stuck on "Connecting…". `ObjectIdentifier` is Sendable, so the
            // capture survives strict concurrency.
            let clientID = ObjectIdentifier(sshClient)
            sshClient.onDisconnect { [weak self] in
                guard let self,
                      let current = self.client,
                      ObjectIdentifier(current) == clientID else { return }
                self.mutableState.withLock {
                    $0.state = .disconnected
                    $0.stdinWriter = nil
                }
                self.onStateChanged?(.disconnected)
            }

            onStateChanged?(.connected)
        } catch {
            dlog("SSH connection error: \(error)")
            transition(to: .failed(error.localizedDescription))
        }
    }

    // MARK: - One-shot command

    /// Run one command and return its stdout, then close the channel.
    ///
    /// Exists so that LOOKING at a host is not the same as JOINING it. Listing
    /// a host's tmux sessions used to require a control client, and a control
    /// client has to attach to some session — so merely opening a host in the
    /// picker attached the user to whatever the default name happened to be,
    /// and resized that session's panes to this device's screen. Browsing must
    /// not have side effects; `tmux list-sessions` is just a command.
    public func run(_ command: String) async -> String? {
        guard let client else { return nil }
        do {
            let out = try await client.executeCommand(command)
            return String(decoding: Data(out.readableBytesView), as: UTF8.self)
        } catch {
            dlog("ssh command failed: \(error)")
            return nil
        }
    }

    // MARK: - Shell

    public func startShell(cols: Int, rows: Int) {
        guard let client = self.client else { return }

        let onData = self.onDataReceived
        let onState = self.onStateChanged
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        // Capture the SSHClient instance so the catch below can tell whether
        // the failure belongs to *our* session or to an already-superseded
        // one (e.g. user popped back to the sessions list, which called
        // disconnect() and started a fresh client). Without this, the
        // closing channel's tail error stomps the new client's .connected
        // state and the UI surfaces "NIOError.ChannelError error 6".
        let runningClient = client
        sessionTask = Task { [weak self] in
            do {
                try await client.withPTY(ptyRequest) { inbound, outbound in
                    let sendableWriter = SendableStdinWriter(writer: outbound)
                    self?.mutableState.withLock { $0.stdinWriter = sendableWriter }

                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer):
                            let data = Data(buffer.readableBytesView)
                            onData?(data)
                        case .stderr(let buffer):
                            let data = Data(buffer.readableBytesView)
                            onData?(data)
                        }
                    }
                }
            } catch {
                // Suppress the error if the service has moved on to a new
                // client (or was explicitly disconnected) — in that case we
                // don't want to clobber the new state with stale failure.
                let stillCurrent = self?.client === runningClient
                guard stillCurrent else { return }

                let errorState = SSHConnectionState.failed(error.localizedDescription)
                self?.mutableState.withLock {
                    $0.state = errorState
                    $0.stdinWriter = nil
                }
                onState?(errorState)
            }
        }
    }

    // MARK: - Input

    public func write(_ data: Data) {
        guard let wrapper = mutableState.withLock({ $0.stdinWriter }) else { return }

        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try? await wrapper.writer.write(buffer)
        }
    }

    public func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        write(data)
    }

    public func resize(cols: Int, rows: Int) {
        guard let wrapper = mutableState.withLock({ $0.stdinWriter }) else { return }

        Task {
            try? await wrapper.writer.changeSize(
                cols: cols,
                rows: rows,
                pixelWidth: 0,
                pixelHeight: 0
            )
        }
    }

    // MARK: - Path-preview file source

    /// Cached per underlying connection so repeated previews reuse one SFTP
    /// channel / source object. Rebuilt after a reconnect (the connection
    /// object's identity changes).
    private var fileSource: (source: any FilePreviewSource, owner: ObjectIdentifier)?

    /// A file source riding the CURRENT connection, or nil while disconnected.
    @MainActor
    public func filePreviewSource() -> (any FilePreviewSource)? {
        if let client {
            let id = ObjectIdentifier(client)
            if let cached = fileSource, cached.owner == id { return cached.source }
            let source = CitadelSFTPFileSource(client: client)
            fileSource = (source, id)
            return source
        }
        return nil
    }

    // MARK: - Liveness probe

    /// Trust the reported state — Citadel surfaces channel death via
    /// `onDisconnect`, and there is no cheap application-level ping on this
    /// path.
    public func probeLiveness() async -> Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Disconnect

    public func disconnect() {
        sessionTask?.cancel()
        sessionTask = nil

        mutableState.withLock {
            $0.stdinWriter = nil
            $0.state = .disconnected
        }

        let clientToClose = client
        client = nil

        if let clientToClose {
            Task {
                try? await clientToClose.close()
            }
        }

        onStateChanged?(.disconnected)
    }
}
#endif
