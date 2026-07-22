#if os(macOS)
import Foundation
import AppKit
import ACPHostKit

/// The v1 executor: everything runs on this Mac via Process. Shell commands
/// go through a login shell (the user's real PATH — nvm, brew, ~/.local/bin);
/// the ACP probe deliberately does NOT: it resolves binaries the way the
/// daemon does (fixed daemon-visible dirs), so a green check proves the
/// daemon will actually find and run the agent. That asymmetry is the whole
/// point — it's what catches the "login shell sees it, daemon doesn't"
/// PATH mismatch as an honest fix rung instead of a dead pane later.
public struct LocalProviderExecutor: ProviderExecutor {
    public init() {}

    // MARK: Shell

    public func runShell(
        _ command: String, onLine: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let buffer = LineBuffer(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.ingest(handle.availableData)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                process.terminationHandler = { p in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    buffer.flush()
                    cont.resume(returning: p.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    onLine("failed to launch: \(error.localizedDescription)")
                    cont.resume(returning: -1)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    // MARK: Probe

    /// Spawn the adapter daemon-style and drive initialize → session/new;
    /// `deep` adds one tiny prompt turn (API-key verification — a bad key
    /// hangs in harness retries, hence the hard deadline). Mirrors
    /// desktop/internal/acphost/host.go `augmentedEnv`/`lookPath` — keep the
    /// dir list in sync with the Go side.
    public func probe(_ preset: ACPAgentPreset, deep: Bool) async -> ProviderProbeOutcome {
        guard let binary = Self.daemonLookPath(preset.command) else { return .notFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = preset.args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.daemonVisibleDirs.joined(separator: ":")
        for (k, v) in preset.env { env[k] = v }
        process.environment = env
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-probe-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        process.currentDirectoryURL = cwd

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let reader = ProbeReader()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            reader.ingest(handle.availableData)
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            try? FileManager.default.removeItem(at: cwd)
        }

        do {
            try process.run()
        } catch {
            return .failed("couldn't launch \(preset.command)")
        }

        func send(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.write(Data("\n".utf8))
        }

        send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
            ],
        ])
        guard await reader.waitForResponse(id: 1, timeout: 20) != nil else {
            return .failed("no response to initialize")
        }

        send([
            "jsonrpc": "2.0", "id": 2, "method": "session/new",
            "params": ["cwd": cwd.path, "mcpServers": [] as [Any]],
        ])
        guard let response = await reader.waitForResponse(id: 2, timeout: 25) else {
            return .failed("no response to session/new")
        }

        if let error = response["error"] as? [String: Any] {
            if error["code"] as? Int == -32000 { return .authRequired }
            return .failed(error["message"] as? String ?? "session/new failed")
        }
        guard let result = response["result"] as? [String: Any],
              let sessionID = result["sessionId"] as? String
        else { return .failed("malformed session/new response") }

        if deep {
            // One tiny turn against the real endpoint — the only proof a
            // pasted key actually works (session/new lies; validated
            // 2026-07-22). Costs a handful of the key's own tokens.
            send([
                "jsonrpc": "2.0", "id": 3, "method": "session/prompt",
                "params": [
                    "sessionId": sessionID,
                    "prompt": [["type": "text", "text": "Reply with exactly: OK"]],
                ],
            ])
            guard let turn = await reader.waitForResponse(id: 3, timeout: 40) else {
                return .failed("no reply from the model — the key may be invalid")
            }
            if let error = turn["error"] as? [String: Any] {
                return .failed(error["message"] as? String ?? "the key was rejected")
            }
        }
        return .ready(model: Self.currentModel(in: result))
    }

    /// The session's current model, for the BYO identity chip. Reads the
    /// configOptions "model" entry (falls back to the models state).
    static func currentModel(in result: [String: Any]) -> String? {
        if let options = result["configOptions"] as? [[String: Any]],
           let model = options.first(where: { $0["category"] as? String == "model" }),
           let value = model["currentValue"] as? String {
            let choices = model["options"] as? [[String: Any]] ?? []
            return choices.first { $0["value"] as? String == value }?["name"] as? String ?? value
        }
        if let models = result["models"] as? [String: Any],
           let value = models["currentModelId"] as? String {
            return value
        }
        return nil
    }

    // MARK: Daemon-visible PATH

    /// Where the daemon's spawn actually looks (host.go augmentedEnv).
    static var daemonVisibleDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "/usr/bin", "/bin",
        ]
    }

    static func daemonLookPath(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in daemonVisibleDirs {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public func binaryFound(_ name: String) async -> Bool {
        Self.daemonLookPath(name) != nil
    }

    // MARK: Human-side actions

    public func openURL(_ url: String) {
        guard let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
    }

    /// Interactive-only vendor sign-ins run in a visible Terminal tab via a
    /// temp `.command` file (same mechanism the old wizard installer used).
    public func openInTerminal(_ command: String) {
        let script = "#!/bin/zsh -l\n\(command)\n"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-signin-\(command.hash.magnitude).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            // Nothing sensible to do; the card's Retry keeps the flow alive.
        }
    }
}

// MARK: - Line plumbing

/// Accumulates pipe chunks into whole lines (thread-safe: readabilityHandler
/// fires on a background queue).
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func ingest(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: data.startIndex..<nl)
            data.removeSubrange(data.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line.trimmingCharacters(in: .init(charactersIn: "\r")))
            }
        }
        lock.unlock()
        for line in lines where !line.isEmpty { onLine(line) }
    }

    func flush() {
        lock.lock()
        let rest = data
        data.removeAll()
        lock.unlock()
        if let line = String(data: rest, encoding: .utf8),
           !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Collects newline-delimited JSON-RPC responses off the probe's stdout and
/// lets the async side await a response by id.
private final class ProbeReader: @unchecked Sendable {
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private let lock = NSLock()

    func ingest(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let id = obj["id"] as? Int {
                responses[id] = obj
            }
        }
        lock.unlock()
    }

    func waitForResponse(id: Int, timeout: TimeInterval) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            lock.lock()
            let hit = responses[id]
            lock.unlock()
            if let hit { return hit }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}
#endif
