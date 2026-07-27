import ACPHostKit
import ACPKit
import Combine
import XCTest

@testable import BentoCore

/// A byte link that hands the daemon's reply over in ONE burst, the way a
/// local unix socket does: every byte is delivered before the client has
/// applied a single line.
private final class BurstLink: AcpByteLink, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    private let cont: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        var c: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { c = $0 }
        cont = c
    }

    func open() async throws {}
    func close() { cont.finish() }

    /// Answer the bootstrap RPCs the way the daemon does for a catch-up
    /// attach: initialize and session/load come back from its cache, so the
    /// agent is never asked to re-replay history.
    func send(_ data: Data) async throws {
        for line in stdioLines(data) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? Int, let method = obj["method"] as? String
            else { continue }
            switch method {
            case "initialize":
                burst([#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"#
                    + #""agentCapabilities":{"loadSession":true}}}"#])
            default:
                burst([#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#])
            }
        }
    }

    /// Frame lines as stdio units (4-byte length + type byte) and deliver them
    /// as a single chunk.
    func burst(_ lines: [String]) {
        var out = Data()
        for line in lines {
            var body = Data([0x02])
            body.append(Data((line + "\n").utf8))
            var len = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(body)
        }
        cont.yield(out)
    }

    /// Unframe client→daemon stdio units (4-byte length + type byte).
    private func stdioLines(_ data: Data) -> [String] {
        var out: [String] = []
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            let len = data[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let bodyStart = i + 4
            guard bodyStart + len <= data.endIndex, len > 0 else { break }
            let body = data[bodyStart..<bodyStart + len]
            if body.first == 0x02, let text = String(data: body.dropFirst(), encoding: .utf8) {
                out.append(contentsOf: text.split(separator: "\n").map(String.init))
            }
            i = bodyStart + len
        }
        return out
    }
}

@MainActor
final class ScrollbackRebuildTests: XCTestCase {
    private func seqUpdate(_ seq: Int, _ inner: String) -> String {
        // The daemon stamps `_seq` FIRST (Go marshals maps with sorted keys).
        #"{"_seq":\#(seq),"jsonrpc":"2.0","method":"session/update","params":"# +
            #"{"sessionId":"ses_test","update":\#(inner)}}"#
    }

    private func toolCall(_ id: String) -> String {
        #"{"sessionUpdate":"tool_call","toolCallId":"\#(id)","title":"\#(id)","status":"completed"}"#
    }

    private func stamped(_ seq: UInt64, _ text: String) -> SessionNotification {
        var note = SessionNotification(
            sessionId: "ses_test",
            update: .agentMessageChunk(.text(text)))
        note.seq = seq
        return note
    }

    private func attach(headSeq: UInt64) -> AttachInfo {
        AttachInfo(agentID: "agent-1", running: true, turnActive: false,
                   acpSessionID: "ses_test", headSeq: headSeq, startSeq: 1, replay: true)
    }

    /// The cold-start regression. The daemon dumps the whole scrollback into a
    /// local socket in milliseconds, so the transport's DELIVERED cursor sits
    /// at head before the first line is applied. Gating the rebuild bracket on
    /// it published an empty transcript one update in and left the rest to land
    /// live — one SwiftUI invalidation per update, the visibly slow "replay"
    /// on every GUI start. The bracket must hold until the backlog is APPLIED.
    func testColdRebuildHoldsUntilTheBacklogIsApplied() async throws {
        // A host transport whose bytes have all been delivered (cursor at
        // head) while nothing has reached the transcript yet — no ACPConnection
        // reads this one, which is exactly the state the old gate misread.
        let link = BurstLink()
        let host = AcpHostTransport(link: link, mode: .plaintext)
        try await host.connect()
        link.burst((1...60).map { seqUpdate($0, toolCall("t\($0)")) })
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(host.lastUpdateSeq, 60, "the whole backlog is on the wire")

        let agent = ScriptedAgentTransport()
        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        let bridge = vm.makeBridge()
        let connection = ACPConnection(transport: agent, handler: bridge)
        await connection.start()

        // Publishes carrying content: the rebuild must surface the transcript
        // exactly once (the empty publish is bootstrap's own reset).
        var publishes = 0
        let sub = vm.$items.dropFirst().sink { if !$0.isEmpty { publishes += 1 } }
        defer { sub.cancel() }

        await vm.bootstrapAttached(
            launch: AgentLaunch(connection: connection, transport: host,
                                attachInfo: attach(headSeq: 60)),
            resumeSessionId: nil)
        XCTAssertEqual(vm.updateSeq, 60, "the reconnect cursor tracks what was delivered")

        // Now the pipeline works through the backlog. Nothing may reach the
        // published transcript until the last line lands.
        for seq in 1...59 {
            vm.handle(stamped(UInt64(seq), "line \(seq) "))
            XCTAssertTrue(vm.items.isEmpty, "published mid-rebuild at seq \(seq)")
        }
        vm.handle(stamped(60, "line 60"))

        XCTAssertEqual(publishes, 1, "the rebuild is exactly one publish")
        let restored = vm.items.compactMap { $0 as? MessageItem }.first { $0.role == .agent }
        XCTAssertEqual(restored?.fullText.hasPrefix("line 1 "), true)
        XCTAssertEqual(restored?.fullText.hasSuffix("line 60"), true)
        vm.shutdown()
    }

    /// The bracket must not hang if the applied cursor can never reach head
    /// (the scrollback carries every agent notification, only `session/update`
    /// moves the cursor). The watchdog publishes what landed instead.
    func testRebuildWatchdogPublishesWhenTheCursorCannotReachHead() async throws {
        let link = BurstLink()
        let host = AcpHostTransport(link: link, mode: .plaintext)
        try await host.connect()

        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        let bridge = vm.makeBridge()
        let connection = ACPConnection(transport: host, handler: bridge)
        await connection.start()

        link.burst([seqUpdate(1, #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"only line"}}"#)])
        try await Task.sleep(nanoseconds: 50_000_000)

        // head=9 is unreachable: seqs 2...9 were notifications the transcript
        // never sees (a non-update line at the head of the log).
        await vm.bootstrapAttached(
            launch: AgentLaunch(connection: connection, transport: host,
                                attachInfo: attach(headSeq: 9)),
            resumeSessionId: nil)
        XCTAssertTrue(vm.items.isEmpty, "the bracket still holds — the cursor is short of head")

        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(vm.items.compactMap { $0 as? MessageItem }.first?.fullText, "only line",
                       "the watchdog published what arrived")
        vm.shutdown()
    }
}
