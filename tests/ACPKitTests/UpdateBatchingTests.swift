import XCTest

@testable import ACPKit

/// Records how updates were GROUPED, not just their contents: the grouping is
/// the point — a client applies one batch in one hop onto its actor, so a
/// backlog costs one UI invalidation instead of one per update.
private actor BatchRecorder: ACPClientHandler {
    private(set) var batches: [[SessionNotification]] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sessionUpdate(_ notification: SessionNotification) async {
        await sessionUpdates([notification])
    }

    func sessionUpdates(_ batch: [SessionNotification]) async {
        batches.append(batch)
        let total = batches.reduce(0) { $0 + $1.count }
        waiters = waiters.filter { count, cont in
            if total >= count {
                cont.resume()
                return false
            }
            return true
        }
    }

    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionOutcome {
        .cancelled
    }

    func waitForUpdates(count: Int) async {
        if batches.reduce(0, { $0 + $1.count }) >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

final class UpdateBatchingTests: XCTestCase {
    private func update(seq: Int?, text: String) -> String {
        let stamp = seq.map { #""_seq":\#($0),"# } ?? ""
        return #"{\#(stamp)"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","#
            + #""update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}}}"#
    }

    /// Everything that arrives in one transport read is handed over together.
    func testUpdatesArrivingTogetherAreOneBatch() async throws {
        let transport = MockTransport()
        let handler = BatchRecorder()
        let conn = ACPConnection(transport: transport, handler: handler)
        await conn.start()

        let lines = (1...60).map { update(seq: $0, text: "line \($0)") }
        transport.injectRaw(lines.joined(separator: "\n") + "\n")
        await handler.waitForUpdates(count: 60)

        let batches = await handler.batches
        XCTAssertEqual(batches.count, 1, "one read of 60 updates must be one hop")
        XCTAssertEqual(batches.first?.count, 60)
        await conn.close()
    }

    /// The daemon's `_seq` stamp rides along, so a client can tell how far a
    /// catch-up replay has actually been APPLIED.
    func testHostSeqStampIsCarriedOnEachUpdate() async throws {
        let transport = MockTransport()
        let handler = BatchRecorder()
        let conn = ACPConnection(transport: transport, handler: handler)
        await conn.start()

        transport.injectRaw(update(seq: 7, text: "stamped") + "\n" + update(seq: nil, text: "live") + "\n")
        await handler.waitForUpdates(count: 2)

        let flat = await handler.batches.flatMap { $0 }
        XCTAssertEqual(flat.first?.seq, 7)
        XCTAssertNil(flat.last?.seq, "an unstamped line (legacy replay) carries no cursor")
        await conn.close()
    }

    /// A response must not overtake the updates that preceded it — a
    /// `session/load` result is the ordering boundary for its replay.
    func testResponseFlushesThePendingBatchFirst() async throws {
        let transport = MockTransport()
        let handler = BatchRecorder()
        let conn = ACPConnection(transport: transport, handler: handler)
        transport.onSend = { data in
            guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = msg["id"] as? Int, msg["method"] as? String == "session/load"
            else { return }
            // The replay and its response land in the SAME read.
            let replay = (1...5).map { self.update(seq: $0, text: "history \($0)") }
            transport.injectRaw(
                replay.joined(separator: "\n") + "\n"
                    + #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"# + "\n")
        }
        await conn.start()
        _ = try await conn.loadSession(sessionId: "s", cwd: "/tmp")
        let seenAtResponse = await handler.batches.reduce(0) { $0 + $1.count }
        XCTAssertEqual(seenAtResponse, 5, "the replay was applied before the load returned")
        await conn.close()
    }
}
