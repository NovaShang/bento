import XCTest

@testable import ACPKit

/// In-process transport whose peer is a scripted fake agent.
final class MockTransport: ACPTransport, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var _onSend: (@Sendable (Data) -> Void)?
    private(set) var closedCount = 0

    init() {
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { cont = $0 }
        continuation = cont
    }

    var onSend: (@Sendable (Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onSend }
        set { lock.lock(); defer { lock.unlock() }; _onSend = newValue }
    }

    func send(_ data: Data) async throws {
        onSend?(data)
    }

    func close() {
        lock.lock()
        closedCount += 1
        lock.unlock()
        continuation.finish()
    }

    /// Agent side: push a raw JSON line to the client.
    func inject(_ json: String) {
        continuation.yield(Data((json + "\n").utf8))
    }

    func injectRaw(_ raw: String) {
        continuation.yield(Data(raw.utf8))
    }

    func fail(_ error: Error) {
        continuation.finish(throwing: error)
    }
}

/// Collects updates; answers permissions with a configurable choice.
actor CollectingHandler: ACPClientHandler {
    private(set) var updates: [SessionNotification] = []
    private(set) var closeError: [Error?] = []
    var permissionChoice: @Sendable (RequestPermissionRequest) -> RequestPermissionOutcome =
        { req in .selected(optionId: req.options.first?.optionId ?? "?") }

    private var updateWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sessionUpdate(_ notification: SessionNotification) async {
        updates.append(notification)
        updateWaiters = updateWaiters.filter { (count, cont) in
            if updates.count >= count {
                cont.resume()
                return false
            }
            return true
        }
    }

    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionOutcome {
        permissionChoice(request)
    }

    func connectionDidClose(error: Error?) async {
        closeError.append(error)
    }

    func setPermissionChoice(_ choice: @escaping @Sendable (RequestPermissionRequest) -> RequestPermissionOutcome) {
        permissionChoice = choice
    }

    func waitForUpdates(count: Int) async {
        if updates.count >= count { return }
        await withCheckedContinuation { cont in
            updateWaiters.append((count, cont))
        }
    }
}

private func decodeSent(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

final class ConnectionTests: XCTestCase {
    func testInitializeRoundTrip() async throws {
        let transport = MockTransport()
        let handler = CollectingHandler()
        let conn = ACPConnection(transport: transport, handler: handler)
        transport.onSend = { data in
            let msg = decodeSent(data)
            guard msg["method"] as? String == "initialize" else { return }
            let params = msg["params"] as! [String: Any]
            XCTAssertEqual(params["protocolVersion"] as? Int, 1)
            let id = msg["id"] as! Int
            transport.inject(
                #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}"#
            )
        }
        await conn.start()
        let resp = try await conn.initialize()
        XCTAssertEqual(resp.protocolVersion, 1)
        XCTAssertEqual(resp.agentCapabilities?.loadSession, true)
        await conn.close()
    }

    func testPromptTurnStreamsUpdatesInOrder() async throws {
        let transport = MockTransport()
        let handler = CollectingHandler()
        let conn = ACPConnection(transport: transport, handler: handler)
        transport.onSend = { data in
            let msg = decodeSent(data)
            guard msg["method"] as? String == "session/prompt" else { return }
            let id = msg["id"] as! Int
            transport.inject(
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}}}"#
            )
            transport.inject(
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello "}}}}"#
            )
            transport.inject(
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"world"}}}}"#
            )
            transport.inject(
                #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":42}}}"#
            )
            transport.inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"end_turn"}}"#)
        }
        await conn.start()
        let resp = try await conn.prompt(sessionId: "s", blocks: [.text("hi")])
        XCTAssertEqual(resp.stopReason, .endTurn)

        await handler.waitForUpdates(count: 4)
        let updates = await handler.updates
        XCTAssertEqual(updates.count, 4)
        guard case .agentThoughtChunk = updates[0].update else { return XCTFail("update 0") }
        guard case .agentMessageChunk(let b1) = updates[1].update else { return XCTFail("update 1") }
        guard case .agentMessageChunk(let b2) = updates[2].update else { return XCTFail("update 2") }
        guard case .unknown(let type, _) = updates[3].update else { return XCTFail("update 3") }
        XCTAssertEqual(b1.textValue, "Hello ")
        XCTAssertEqual(b2.textValue, "world")
        XCTAssertEqual(type, "usage_update")
        await conn.close()
    }

    func testPermissionRequestAnsweredWhilePromptPending() async throws {
        let transport = MockTransport()
        let handler = CollectingHandler()
        await handler.setPermissionChoice { req in
            .selected(optionId: req.options.first { $0.kind == .allowOnce }!.optionId)
        }
        let conn = ACPConnection(transport: transport, handler: handler)

        let permissionAnswered = expectation(description: "permission response sent")
        transport.onSend = { data in
            let msg = decodeSent(data)
            if msg["method"] as? String == "session/prompt" {
                let id = msg["id"] as! Int
                // Agent asks permission mid-turn (its own request id 99).
                transport.inject(
                    #"{"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"c1","title":"Run ls"},"options":[{"optionId":"ok","name":"Allow","kind":"allow_once"},{"optionId":"no","name":"Deny","kind":"reject_once"}]}}"#
                )
                // Turn completion arrives after the permission answer below.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    transport.inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"end_turn"}}"#)
                }
            } else if (msg["id"] as? Int) == 99 {
                let result = msg["result"] as! [String: Any]
                let outcome = result["outcome"] as! [String: Any]
                XCTAssertEqual(outcome["outcome"] as? String, "selected")
                XCTAssertEqual(outcome["optionId"] as? String, "ok")
                permissionAnswered.fulfill()
            }
        }
        await conn.start()
        let resp = try await conn.prompt(sessionId: "s", blocks: [.text("run it")])
        XCTAssertEqual(resp.stopReason, .endTurn)
        await fulfillment(of: [permissionAnswered], timeout: 2)
        await conn.close()
    }

    func testRPCErrorSurfacesAsThrow() async throws {
        let transport = MockTransport()
        let conn = ACPConnection(transport: transport, handler: CollectingHandler())
        transport.onSend = { data in
            let msg = decodeSent(data)
            guard let id = msg["id"] as? Int else { return }
            transport.inject(
                #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"auth required"}}"#)
        }
        await conn.start()
        do {
            _ = try await conn.newSession(cwd: "/tmp")
            XCTFail("expected throw")
        } catch let ACPError.rpc(obj) {
            XCTAssertEqual(obj.code, -32000)
            XCTAssertEqual(obj.message, "auth required")
        }
        await conn.close()
    }

    func testTransportDeathFailsPendingRequests() async throws {
        let transport = MockTransport()
        let handler = CollectingHandler()
        let conn = ACPConnection(transport: transport, handler: handler)
        transport.onSend = { data in
            let msg = decodeSent(data)
            guard msg["method"] as? String == "session/prompt" else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                transport.fail(ACPError.transportClosed)
            }
        }
        await conn.start()
        do {
            _ = try await conn.prompt(sessionId: "s", blocks: [.text("hi")])
            XCTFail("expected throw")
        } catch {
            // expected
        }
        let closes = await handler.closeError
        XCTAssertEqual(closes.count, 1)
    }

    func testGarbageLinesIgnored() async throws {
        let transport = MockTransport()
        let handler = CollectingHandler()
        let conn = ACPConnection(transport: transport, handler: handler)
        transport.onSend = { data in
            let msg = decodeSent(data)
            guard let id = msg["id"] as? Int else { return }
            transport.injectRaw("some log line the agent printed\n")
            transport.inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1}}"#)
        }
        await conn.start()
        let resp = try await conn.initialize()
        XCTAssertEqual(resp.protocolVersion, 1)
        await conn.close()
    }

    func testCancelIsNotification() async throws {
        let transport = MockTransport()
        let conn = ACPConnection(transport: transport, handler: CollectingHandler())
        let sent = expectation(description: "cancel sent")
        transport.onSend = { data in
            let msg = decodeSent(data)
            XCTAssertEqual(msg["method"] as? String, "session/cancel")
            XCTAssertNil(msg["id"])  // notifications carry no id
            let params = msg["params"] as! [String: Any]
            XCTAssertEqual(params["sessionId"] as? String, "s")
            sent.fulfill()
        }
        await conn.start()
        try await conn.cancel(sessionId: "s")
        await fulfillment(of: [sent], timeout: 2)
        await conn.close()
    }
}
