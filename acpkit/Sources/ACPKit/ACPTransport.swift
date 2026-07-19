import Foundation

/// A bidirectional byte channel carrying newline-delimited JSON-RPC.
/// Local implementation spawns the agent process (macOS); the iOS app
/// provides a relay-backed implementation.
public protocol ACPTransport: Sendable {
    /// Raw bytes as they arrive — chunk boundaries carry no meaning.
    /// The stream finishes when the peer goes away (throwing on abnormal end).
    var incoming: AsyncThrowingStream<Data, Error> { get }

    func send(_ data: Data) async throws

    /// Tear down the channel. Idempotent.
    func close()
}

#if os(macOS)

/// Spawns an agent as a child process and speaks ACP over its stdio.
/// Commands resolve through /usr/bin/env so PATH lookups behave like a shell.
public final class ProcessTransport: ACPTransport, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let incomingContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let writeLock = NSLock()
    private var closed = false

    /// Lines from the agent's stderr, for diagnostics.
    public var onStderrLine: (@Sendable (String) -> Void)?

    public init(
        command: String,
        arguments: [String] = [],
        cwd: String? = nil,
        environment: [String: String] = [:]
    ) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { continuation = $0 }
        incomingContinuation = continuation

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        // GUI apps inherit a minimal PATH; make sure common install
        // locations resolve (homebrew, npm/bun globals, ~/.local).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
        ]
        let basePath = env["PATH"] ?? "/usr/bin:/bin"
        let missing = extraPaths.filter { !basePath.split(separator: ":").map(String.init).contains($0) }
        env["PATH"] = (missing + [basePath]).joined(separator: ":")
        for (k, v) in environment { env[k] = v }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    public func start() throws {
        let continuation = incomingContinuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }

        var stderrBuffer = NDJSONLineBuffer()
        let stderrCallback = { [weak self] (line: String) in self?.onStderrLine?(line) }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for lineData in stderrBuffer.append(data) {
                if let line = String(data: lineData, encoding: .utf8) {
                    stderrCallback(line)
                }
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.incomingContinuation.finish()
        }

        try process.run()
    }

    public func send(_ data: Data) async throws {
        try syncWrite(data)
    }

    private func syncWrite(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed, process.isRunning else { throw ACPError.transportClosed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // Escalate if the agent ignores SIGTERM.
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.interrupt() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        incomingContinuation.finish()
    }

    public var isRunning: Bool { process.isRunning }

    deinit {
        close()
    }
}

#endif
