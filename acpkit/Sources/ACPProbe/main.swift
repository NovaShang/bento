// acp-probe: drives a real ACP agent end-to-end from the command line.
// Verification harness for ACPKit against e.g. `opencode acp`.
//
//   acp-probe --cwd ~/proj --prompt "Reply with exactly PONG" -- opencode acp
//
// Auto-approves permission requests (prefers allow_once) and prints every
// session update. Exits non-zero on protocol errors.

import ACPKit
import Foundation

#if os(macOS)

struct ProbeArgs {
    var cwd = FileManager.default.currentDirectoryPath
    var prompt = "Reply with exactly the word PONG and nothing else."
    var trace = false
    var command: [String] = ["opencode", "acp"]
}

func parseArgs() -> ProbeArgs {
    var args = ProbeArgs()
    var rest = Array(CommandLine.arguments.dropFirst())
    while !rest.isEmpty {
        let arg = rest.removeFirst()
        switch arg {
        case "--cwd": args.cwd = rest.removeFirst()
        case "--prompt", "-p": args.prompt = rest.removeFirst()
        case "--trace": args.trace = true
        case "--":
            args.command = rest
            rest = []
        default:
            FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
            exit(2)
        }
    }
    return args
}

final class ProbeHandler: ACPClientHandler {
    func sessionUpdate(_ notification: SessionNotification) async {
        switch notification.update {
        case .agentMessageChunk(let block):
            print("[message] \(block.textValue ?? "<non-text>")")
        case .agentThoughtChunk(let block):
            print("[thought] \(block.textValue ?? "<non-text>")")
        case .userMessageChunk(let block):
            print("[user] \(block.textValue ?? "<non-text>")")
        case .toolCall(let call):
            print("[tool_call] \(call.toolCallId) kind=\(call.kind?.rawValue ?? "?") status=\(call.status?.rawValue ?? "?") \(call.title ?? "")")
        case .toolCallUpdate(let call):
            var extra = ""
            if let content = call.content {
                for item in content {
                    if case .diff(let path, _, _) = item { extra += " diff:\(path)" }
                }
            }
            print("[tool_update] \(call.toolCallId) status=\(call.status?.rawValue ?? "?")\(extra)")
        case .plan(let entries):
            print("[plan] \(entries.map { "\($0.status.rawValue):\($0.content)" }.joined(separator: " | "))")
        case .availableCommandsUpdate(let commands):
            print("[commands] \(commands.count) available")
        case .currentModeUpdate(let modeId):
            print("[mode] \(modeId)")
        case .unknown(let type, _):
            print("[\(type)] (non-spec update)")
        }
    }

    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionOutcome {
        let pick = request.options.first { $0.kind == .allowOnce } ?? request.options.first
        print("[permission] \(request.toolCall.title ?? request.toolCall.toolCallId) -> \(pick?.optionId ?? "cancel")")
        if let pick { return .selected(optionId: pick.optionId) }
        return .cancelled
    }

    func connectionDidClose(error: Error?) async {
        if let error { print("[closed] \(error)") }
    }
}

let args = parseArgs()
let start = Date()

let transport = ProcessTransport(
    command: args.command[0],
    arguments: Array(args.command.dropFirst()),
    cwd: args.cwd)
transport.onStderrLine = { line in
    FileHandle.standardError.write(Data("[agent-stderr] \(line)\n".utf8))
}

let connection = ACPConnection(transport: transport, handler: ProbeHandler())

let task = Task {
    do {
        try transport.start()
        await connection.start()
        if args.trace {
            await connection.setTrace { outbound, line in
                let dir = outbound ? ">>" : "<<"
                FileHandle.standardError.write(
                    Data("\(dir) \(String(data: line, encoding: .utf8) ?? "?")\n".utf8))
            }
        }

        let initResp = try await connection.initialize()
        print("INIT ok protocol=\(initResp.protocolVersion) agent=\(initResp.agentInfo?.name ?? "?") loadSession=\(initResp.agentCapabilities?.loadSession ?? false)")

        let session = try await connection.newSession(cwd: args.cwd)
        print("SESSION \(session.sessionId) modes=\(session.modes?.availableModes.map(\.id) ?? []) model=\(session.models?.currentModelId ?? "?")")

        let resp = try await connection.prompt(sessionId: session.sessionId, blocks: [.text(args.prompt)])
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("DONE stopReason=\(resp.stopReason.rawValue) in \(ms)ms")
        await connection.close()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("PROBE FAILED: \(error)\n".utf8))
        await connection.close()
        exit(1)
    }
}

// Keep the run loop alive for Process/FileHandle callbacks.
withExtendedLifetime(task) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 600))
}
exit(3)

#else

print("acp-probe is macOS-only")

#endif
