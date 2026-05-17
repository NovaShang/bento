import Foundation
import Citadel
import Crypto
import NIO
import NIOSSH
import os

enum SSHConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

enum SSHError: LocalizedError {
    case notConnected
    case invalidKeyFormat

    var errorDescription: String? {
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

/// Manages an SSH connection and interactive shell session.
final class SSHService: @unchecked Sendable {
    private let mutableState = OSAllocatedUnfairLock(initialState: SSHMutableState())
    private var client: SSHClient?
    private var sessionTask: Task<Void, Never>?

    var state: SSHConnectionState {
        mutableState.withLock { $0.state }
    }

    /// Called on each chunk of terminal output
    var onDataReceived: (@Sendable (Data) -> Void)?
    var onStateChanged: (@Sendable (SSHConnectionState) -> Void)?

    // MARK: - Connect

    func connect(host: Host) async {
        mutableState.withLock { $0.state = .connecting }
        onStateChanged?(.connecting)

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
            let errorState = SSHConnectionState.failed(error.localizedDescription)
            mutableState.withLock { $0.state = errorState }
            onStateChanged?(errorState)
        }
    }

    // MARK: - Shell

    func startShell(cols: Int, rows: Int) {
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

    func write(_ data: Data) {
        guard let wrapper = mutableState.withLock({ $0.stdinWriter }) else { return }

        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try? await wrapper.writer.write(buffer)
        }
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        write(data)
    }

    func resize(cols: Int, rows: Int) {
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

    // MARK: - Disconnect

    func disconnect() {
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
