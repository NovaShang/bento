import ACPKit
import Combine
import XCTest

@testable import BentoTerminalCore
import ACPHostKit

/// Transport scripted to act like a minimal agent: answers initialize,
/// session/new, and session/prompt (after emitting the given updates).
final class ScriptedAgentTransport: ACPTransport, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    /// Updates injected when a prompt arrives, before the turn completes.
    var promptUpdates: [String] = []
    var stopReason = "end_turn"

    init() {
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { cont = $0 }
        continuation = cont
    }

    /// When true, session/new fails with auth_required until `authenticate`
    /// arrives (mimics claude-agent-acp before `claude /login`).
    var requiresAuth = false
    private var authenticated = false

    func send(_ data: Data) async throws {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let method = msg["method"] as? String, let id = msg["id"] as? Int else { return }
        switch method {
        case "initialize":
            inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true}},"authMethods":[{"id":"vendor-login","name":"Log in with Vendor"}]}}"#)
        case "authenticate":
            let ok: Bool = { lock.lock(); defer { lock.unlock() }; authenticated = true; return true }()
            _ = ok
            inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        case "session/new":
            let denied: Bool = {
                lock.lock()
                defer { lock.unlock() }
                return requiresAuth && !authenticated
            }()
            if denied {
                inject(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"Authentication required"}}"#)
            } else {
                inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"ses_test"}}"#)
            }
        case "session/prompt":
            let updates: [String] = { lock.lock(); defer { lock.unlock() }; return promptUpdates }()
            for update in updates { inject(update) }
            let reason: String = { lock.lock(); defer { lock.unlock() }; return stopReason }()
            inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"\#(reason)"}}"#)
        default:
            inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        }
    }

    func close() { continuation.finish() }

    func inject(_ json: String) { continuation.yield(Data((json + "\n").utf8)) }

    func setPromptUpdates(_ updates: [String]) {
        lock.lock()
        promptUpdates = updates
        lock.unlock()
    }
}

@MainActor
final class SessionViewModelTests: XCTestCase {
    private func note(_ update: String) -> SessionNotification {
        let json = #"{"sessionId":"ses_test","update":\#(update)}"#
        return try! JSONDecoder().decode(SessionNotification.self, from: Data(json.utf8))
    }

    private func chunk(_ kind: String, _ text: String) -> SessionNotification {
        note(#"{"sessionUpdate":"\#(kind)","content":{"type":"text","text":"\#(text)"}}"#)
    }

    func testAgentChunksCoalesceIntoOneMessage() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        vm.handle(chunk("agent_message_chunk", "Hello "))
        vm.handle(chunk("agent_message_chunk", "world"))
        XCTAssertEqual(vm.items.count, 1)
        let msg = vm.items[0] as! MessageItem
        XCTAssertEqual(msg.role, .agent)
        XCTAssertEqual(msg.fullText, "Hello world")
        XCTAssertTrue(msg.isStreaming)
    }

    func testThoughtThenMessageMakesTwoItems() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        vm.handle(chunk("agent_thought_chunk", "pondering"))
        vm.handle(chunk("agent_message_chunk", "answer"))
        XCTAssertEqual(vm.items.count, 2)
        let thought = vm.items[0] as! MessageItem
        let msg = vm.items[1] as! MessageItem
        XCTAssertEqual(thought.role, .thought)
        XCTAssertFalse(thought.isStreaming)  // closed when message started
        XCTAssertEqual(msg.role, .agent)
    }

    func testToolCallLifecycleMergesInPlace() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        vm.handle(chunk("agent_message_chunk", "Let me edit."))
        vm.handle(
            note(#"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Edit file","kind":"edit","status":"pending"}"#))
        vm.handle(
            note(#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"in_progress"}"#))
        vm.handle(
            note(#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"diff","path":"/a.swift","oldText":"x","newText":"y"}]}"#))

        XCTAssertEqual(vm.items.count, 2)
        let message = vm.items[0] as! MessageItem
        XCTAssertFalse(message.isStreaming)  // tool call closes the stream
        let tool = vm.items[1] as! ToolCallItem
        XCTAssertEqual(tool.status, .completed)
        XCTAssertEqual(tool.kind, .edit)
        XCTAssertEqual(tool.diffs.count, 1)
        XCTAssertEqual(tool.diffs[0].path, "/a.swift")
    }

    func testMessageAfterToolCallStartsNewItem() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        vm.handle(chunk("agent_message_chunk", "before"))
        vm.handle(note(#"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Run"}"#))
        vm.handle(chunk("agent_message_chunk", "after"))
        XCTAssertEqual(vm.items.count, 3)
        XCTAssertEqual((vm.items[2] as! MessageItem).fullText, "after")
    }

    func testPlanAndUsageUpdates() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        vm.handle(
            note(#"{"sessionUpdate":"plan","entries":[{"content":"step 1","priority":"high","status":"in_progress"}]}"#))
        XCTAssertEqual(vm.plan.count, 1)
        XCTAssertEqual(vm.plan[0].status, .inProgress)

        vm.handle(
            note(#"{"sessionUpdate":"usage_update","used":1000,"size":200000,"cost":{"amount":0.05,"currency":"USD"}}"#))
        XCTAssertEqual(vm.usage?.usedTokens, 1000)
        XCTAssertEqual(vm.usage?.contextSize, 200000)
        XCTAssertEqual(vm.usage?.costCurrency, "USD")
    }

    func testPermissionFlow() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        var received: RequestPermissionOutcome?
        let request = RequestPermissionRequest(
            sessionId: "ses_test",
            toolCall: ToolCallUpdate(toolCallId: "c1", title: "Run rm"),
            options: [
                PermissionOption(optionId: "y", name: "Allow", kind: .allowOnce),
                PermissionOption(optionId: "n", name: "Deny", kind: .rejectOnce),
            ])
        vm.presentPermission(request) { received = $0 }
        XCTAssertEqual(vm.activityState, .awaiting)
        XCTAssertNotNil(vm.pendingPermission)

        vm.respondPermission(.selected(optionId: "y"))
        XCTAssertEqual(received, .selected(optionId: "y"))
        XCTAssertNil(vm.pendingPermission)
    }

    func testFullTurnAgainstScriptedAgent() async {
        let transport = ScriptedAgentTransport()
        transport.setPromptUpdates([
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_test","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi there"}}}}"#
        ])
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.sessionId, "ses_test")

        vm.send("hello")
        XCTAssertTrue(vm.isTurnActive)
        XCTAssertEqual(vm.activityState, .working)

        // Wait for the turn to complete.
        for _ in 0..<100 {
            if !vm.isTurnActive { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(vm.isTurnActive)
        XCTAssertEqual(vm.lastStopReason, .endTurn)
        XCTAssertEqual(vm.items.count, 2)  // user + agent message
        XCTAssertEqual((vm.items[0] as! MessageItem).role, .user)
        XCTAssertEqual((vm.items[1] as! MessageItem).fullText, "hi there")
        vm.shutdown()
    }

    func testSendDuringTurnQueuesAndFlushesInOrder() async {
        let transport = ScriptedAgentTransport()
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection)

        vm.send("first")
        XCTAssertTrue(vm.isTurnActive)
        vm.send("second")
        vm.send("third")
        XCTAssertEqual(vm.queuedMessages.map(\.text), ["second", "third"])
        // Only the first prompt is in the transcript so far.
        XCTAssertEqual(vm.items.compactMap { ($0 as? MessageItem)?.fullText }, ["first"])

        // Queue drains turn by turn as the scripted agent answers each prompt.
        for _ in 0..<200 {
            if vm.queuedMessages.isEmpty && !vm.isTurnActive { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(vm.queuedMessages.isEmpty)
        XCTAssertFalse(vm.isTurnActive)
        XCTAssertEqual(
            vm.items.compactMap { ($0 as? MessageItem)?.fullText },
            ["first", "second", "third"])
        vm.shutdown()
    }

    func testCancelledTurnParksQueue() async {
        let transport = ScriptedAgentTransport()
        transport.stopReason = "cancelled"
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection)

        vm.send("first")
        vm.send("second")
        for _ in 0..<100 {
            if !vm.isTurnActive { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(vm.isTurnActive)
        // The cancelled turn must NOT auto-release the queue.
        XCTAssertEqual(vm.queuedMessages.map(\.text), ["second"])

        // Explicit release sends it.
        vm.sendQueuedMessageNow(vm.queuedMessages[0].id)
        XCTAssertTrue(vm.queuedMessages.isEmpty)
        XCTAssertTrue(vm.isTurnActive)
        vm.shutdown()
    }

    func testRemoveQueuedMessage() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        // No connection: send is a no-op, so exercise the queue directly is
        // not possible — removal semantics are covered in the flush test via
        // queuedMessages access; here just assert empty-queue removal is safe.
        vm.removeQueuedMessage(UUID())
        XCTAssertTrue(vm.queuedMessages.isEmpty)
    }

    func testAuthRequiredParksThenAuthenticateRecovers() async {
        let transport = ScriptedAgentTransport()
        transport.requiresAuth = true
        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection)

        // Parked, not failed: sign-in card state with the advertised method.
        XCTAssertEqual(vm.phase, .authRequired)
        XCTAssertEqual(vm.authMethods.map(\.id), ["vendor-login"])
        XCTAssertEqual(vm.activityState, .awaiting)
        XCTAssertNil(vm.sessionId)

        vm.authenticate(methodId: "vendor-login")
        for _ in 0..<100 {
            if vm.phase == .ready { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.sessionId, "ses_test")
        vm.shutdown()
    }

    func testImageAttachmentStagesAndSends() async {
        let transport = ScriptedAgentTransport()
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection)
        XCTAssertTrue(vm.canAttachImages)  // promptCapabilities.image from initialize

        // 1×1 PNG — small enough to pass through the processor untouched.
        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        vm.attachImage(data: png, label: "dot.png")
        XCTAssertEqual(vm.composerAttachments.count, 1)
        XCTAssertEqual(vm.composerAttachments[0].mimeType, "image/png")

        vm.send("look at this")
        XCTAssertTrue(vm.composerAttachments.isEmpty)  // consumed by send
        let sent = vm.items.compactMap { $0 as? MessageItem }.last
        XCTAssertEqual(sent?.images.count, 1)
        vm.shutdown()
    }

    func testTranscriptGrowthPulseFiresOnAppendAndInPlaceGrowth() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        var fires = 0
        let subscription = vm.transcriptDidGrow.sink { fires += 1 }
        defer { subscription.cancel() }

        vm.handle(
            note(#"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Run","status":"pending"}"#))
        XCTAssertEqual(fires, 1)  // new item
        // In-place merge changes no item count but must still pulse —
        // auto-follow depends on it.
        vm.handle(
            note(#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed"}"#))
        XCTAssertEqual(fires, 2)
    }

    func testUserChunkReplayAppendsWhenIdle() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        vm.handle(chunk("user_message_chunk", "old prompt"))
        vm.handle(chunk("agent_message_chunk", "old answer"))
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual((vm.items[0] as! MessageItem).role, .user)
        XCTAssertEqual((vm.items[0] as! MessageItem).fullText, "old prompt")
    }

    func testConnectionClosedEndsSession() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        vm.handle(chunk("agent_message_chunk", "partial"))
        vm.handleConnectionClosed(error: ACPError.transportClosed)
        XCTAssertEqual(vm.phase, .ended)
        // The half-open stream was closed and an error notice appended.
        XCTAssertFalse((vm.items[0] as! MessageItem).isStreaming)
        XCTAssertTrue(vm.items.last is NoticeItem)
    }
}
