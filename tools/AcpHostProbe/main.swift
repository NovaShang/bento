// acp-host-probe: end-to-end verification of the persistent agent host.
//
//   acp-host-probe --socket ~/.bento/acp.sock --cwd DIR
//
// Flow: spawn agent → initialize → session/new → prompt → DETACH (close the
// stream; daemon must keep the agent) → new stream → list (find it) →
// attach → initialize (cached) → session/load (history replays, must
// contain the first exchange) → second prompt → kill. Exits non-zero on
// any mismatch. This scripts the old "sessions outlive everything"
// guarantee on the ACP stack.

import ACPKit
import BentoFoundation
import BentoLink
import BentoWorkbench
import Foundation

#if os(macOS)

struct Args {
    var socket = NSHomeDirectory() + "/.bento/acp.sock"
    var cwd = FileManager.default.currentDirectoryPath
    var command = ["opencode", "acp"]
}

func parseArgs() -> Args {
    var args = Args()
    var rest = Array(CommandLine.arguments.dropFirst())
    while !rest.isEmpty {
        let arg = rest.removeFirst()
        switch arg {
        case "--socket": args.socket = (rest.removeFirst() as NSString).expandingTildeInPath
        case "--cwd": args.cwd = rest.removeFirst()
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

/// Collects updates; auto-allows permissions.
final class ProbeHandler: ACPClientHandler, @unchecked Sendable {
    let label: String
    private let lock = NSLock()
    private var _messages: [String] = []

    init(label: String) { self.label = label }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }

    func sessionUpdate(_ notification: SessionNotification) async {
        switch notification.update {
        case .agentMessageChunk(let block), .userMessageChunk(let block):
            if let text = block.textValue {
                lock.lock()
                _messages.append(text)
                lock.unlock()
                print("[\(label)] chunk: \(text.prefix(60))")
            }
        case .toolCall(let call):
            print("[\(label)] tool: \(call.title ?? call.toolCallId)")
        default:
            break
        }
    }

    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionOutcome {
        let pick = request.options.first { $0.kind == .allowOnce } ?? request.options.first
        if let pick { return .selected(optionId: pick.optionId) }
        return .cancelled
    }

    func connectionDidClose(error: Error?) async {}
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

let args = parseArgs()

let task = Task {
    func ms(_ from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }
    // ---- Phase 1: spawn, prompt, detach ----
    let tConnect = Date()
    let t1 = AcpHostTransportFactory.local(socketPath: args.socket)
    try await t1.connect()
    print("TIMING connect=\(ms(tConnect))ms")
    let tSpawn = Date()
    let spawned = try await t1.spawn(
        command: args.command[0], args: Array(args.command.dropFirst()),
        cwd: args.cwd, env: [:])
    print("SPAWNED agent_id=\(spawned.agentID) TIMING spawn=\(ms(tSpawn))ms")

    let h1 = ProbeHandler(label: "conn1")
    let c1 = ACPConnection(transport: t1, handler: h1)
    await c1.start()
    let tInit = Date()
    let initResp = try await c1.initialize()
    print("INIT protocol=\(initResp.protocolVersion) loadSession=\(initResp.agentCapabilities?.loadSession ?? false) TIMING initialize=\(ms(tInit))ms")
    let tSess = Date()
    let sess = try await c1.newSession(cwd: args.cwd)
    print("SESSION \(sess.sessionId) TIMING session/new=\(ms(tSess))ms")
    let marker = "BENTO-PERSIST-\(Int.random(in: 1000...9999))"
    let resp1 = try await c1.prompt(
        sessionId: sess.sessionId,
        blocks: [.text("Reply with exactly the word \(marker) and nothing else.")])
    print("TURN1 \(resp1.stopReason.rawValue)")
    guard h1.messages.joined().contains(marker) else {
        fail("first reply did not contain marker")
    }

    await c1.close()  // stream gone — daemon must keep the agent
    print("DETACHED (stream closed)")
    try await Task.sleep(nanoseconds: 500_000_000)

    // ---- Phase 2: new stream, list, attach, history, second turn ----
    let t2 = AcpHostTransportFactory.local(socketPath: args.socket)
    try await t2.connect()
    let agents = try await t2.listAgents()
    print("LIST \(agents.map { "\($0.id):running=\($0.running):attached=\($0.attached)" })")
    guard let row = agents.first(where: { $0.id == spawned.agentID }) else {
        fail("agent missing from list after detach")
    }
    guard row.running else { fail("agent not running after detach — persistence broken") }
    guard !row.attached else { fail("agent still marked attached") }
    guard row.acpSessionId == sess.sessionId else {
        fail("daemon did not sniff acp session id (got \(row.acpSessionId ?? "nil"))")
    }

    let h2 = ProbeHandler(label: "conn2")
    let attachInfo = try await t2.attach(agentID: spawned.agentID)
    print("ATTACHED running=\(attachInfo.running) turnActive=\(attachInfo.turnActive) session=\(attachInfo.acpSessionID ?? "-")")
    let c2 = ACPConnection(transport: t2, handler: h2)
    await c2.start()
    let init2 = try await c2.initialize()  // served from daemon cache
    guard init2.protocolVersion >= 1 else { fail("cached initialize invalid") }
    print("INIT2 ok (cached)")

    _ = try await c2.loadSession(sessionId: sess.sessionId, cwd: args.cwd)
    try await Task.sleep(nanoseconds: 500_000_000)
    guard h2.messages.joined().contains(marker) else {
        fail("history replay missing first-turn marker")
    }
    print("HISTORY ok (marker replayed)")

    let resp2 = try await c2.prompt(
        sessionId: sess.sessionId, blocks: [.text("Reply with exactly the word PONG2.")])
    print("TURN2 \(resp2.stopReason.rawValue)")
    guard h2.messages.joined().contains("PONG2") else { fail("second turn failed") }

    // ---- Phase 3: the conversation outlives its process ----
    // Kill the agent, then relaunch through the LAUNCHER naming the
    // conversation. That is what a pane does when the daemon restarted
    // under it: the daemon must bind the conversation's durable log and
    // serve the missed tail rather than hand back a blank transcript.
    t2.killAgent(id: spawned.agentID)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    await c2.close()

    let launcher = DaemonAgentLauncher(socketPath: args.socket)
    let preset = ACPAgentPreset(
        id: "probe", name: "probe", command: args.command[0],
        args: Array(args.command.dropFirst()), env: [:])
    let h3 = ProbeHandler(label: "conn3")
    let relaunched = try await launcher.launch(
        preset: preset, cwd: args.cwd, conversationID: sess.sessionId,
        haveSeq: 1, holdsTranscript: false, handler: h3)
    guard let info = relaunched.attachInfo else { fail("relaunch returned no attach info") }
    print("RELAUNCH agent=\(info.agentID) replay=\(info.replay) head=\(info.headSeq) start=\(info.startSeq)")
    guard info.replay else {
        fail("no catch-up replay after the process died — the durable log was not bound")
    }
    guard info.headSeq > 1 else { fail("log head did not survive (head=\(info.headSeq))") }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    guard h3.messages.joined().contains("PONG2") else {
        fail("the missed tail was not replayed from the log")
    }
    guard !h3.messages.joined().contains(marker) else {
        fail("replay ignored the cursor: seq 1 was already applied and must not be resent")
    }
    print("DURABLE LOG ok (delta from seq 1, no full rebuild)")

    relaunched.transport?.killAgent(id: info.agentID)
    try await Task.sleep(nanoseconds: 300_000_000)
    await relaunched.connection.close()
    print("PERSISTENCE E2E: ALL OK")
    exit(0)
}

withExtendedLifetime(task) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 300))
}
fail("timeout")

#else
print("macOS only")
#endif
