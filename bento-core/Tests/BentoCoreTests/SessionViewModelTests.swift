import ACPKit
import Combine
import XCTest

@testable import BentoCore
import ACPHostKit

/// Transport scripted to act like a minimal agent: answers initialize,
/// session/new, and session/prompt (after emitting the given updates).
final class ScriptedAgentTransport: ACPTransport, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    /// Updates injected when a prompt arrives, before the turn completes.
    var promptUpdates: [String] = []
    /// When true, a `session/prompt` is accepted but NEVER answered — the turn
    /// stays active with no local prompt-response completing it, mimicking a
    /// daemon-hosted turn that ends via a `turnDone` host event (the detached
    /// path) rather than through the client's own `connection.prompt` await.
    var suppressPromptResponse = false
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

    /// Full `session/update` notification lines streamed back (in order)
    /// when a `session/load` arrives, before its result — the replay a real
    /// agent performs when resuming a stored conversation.
    var loadUpdates: [String] = []

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
        case "session/load":
            let updates: [String] = { lock.lock(); defer { lock.unlock() }; return loadUpdates }()
            for update in updates { inject(update) }
            inject(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        case "session/prompt":
            let suppress: Bool = { lock.lock(); defer { lock.unlock() }; return suppressPromptResponse }()
            if suppress { return }  // turn stays active; no local response completes it
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

    func testSessionInfoUpdateSetsTitleAndFiresHook() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        var hookFires = 0
        vm.onSessionTitleChange = { hookFires += 1 }

        vm.handle(
            note(#"{"sessionUpdate":"session_info_update","title":"ui-improve","updatedAt":"2026-07-20T00:00:00Z"}"#))
        XCTAssertEqual(vm.sessionTitle, "ui-improve")
        XCTAssertEqual(hookFires, 1)

        // Unchanged title re-sent at the next turn end: no redundant refresh.
        vm.handle(note(#"{"sessionUpdate":"session_info_update","title":"ui-improve"}"#))
        XCTAssertEqual(hookFires, 1)

        // Empty titles never clobber a real one.
        vm.handle(note(#"{"sessionUpdate":"session_info_update","title":""}"#))
        XCTAssertEqual(vm.sessionTitle, "ui-improve")

        vm.handle(note(#"{"sessionUpdate":"session_info_update","title":"renamed"}"#))
        XCTAssertEqual(vm.sessionTitle, "renamed")
        XCTAssertEqual(hookFires, 2)
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

    /// The daemon/detached turn-end path (a `turnDone` host event, not the
    /// client's own `connection.prompt` await) must ALSO release the queue.
    /// The bug: only the local prompt completion flushed, so daemon-hosted
    /// turns — the real runtime — left queued prompts stranded forever.
    func testDetachedTurnEndFlushesQueue() async {
        let transport = ScriptedAgentTransport()
        transport.suppressPromptResponse = true  // only the host event ends the turn
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = vm.makeBridge()
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrapAttached(
            launch: AgentLaunch(
                connection: connection, transport: nil,
                attachInfo: AttachInfo(agentID: "agent-1", running: true,
                                       turnActive: false, acpSessionID: "ses_test")),
            resumeSessionId: nil)

        vm.send("first")
        XCTAssertTrue(vm.isTurnActive)
        vm.send("second")
        XCTAssertEqual(vm.queuedMessages.map(\.text), ["second"])

        // The daemon reports the turn finished while we hold no prompt await.
        vm.handleHostEvent(.turnFinishedWhileDetached(stopReason: "end_turn"))

        XCTAssertTrue(vm.queuedMessages.isEmpty, "detached turn end must release the queue")
        XCTAssertTrue(vm.isTurnActive, "flushing 'second' starts a new turn")
        XCTAssertEqual(
            vm.items.compactMap { ($0 as? MessageItem)?.fullText }, ["first", "second"])
        vm.shutdown()
    }

    /// A cancelled detached turn parks the queue, exactly like a cancelled
    /// local turn — cancel means "stop", not "go on with the next thing".
    func testDetachedCancelledTurnParksQueue() async {
        let transport = ScriptedAgentTransport()
        transport.suppressPromptResponse = true
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = vm.makeBridge()
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrapAttached(
            launch: AgentLaunch(
                connection: connection, transport: nil,
                attachInfo: AttachInfo(agentID: "agent-1", running: true,
                                       turnActive: false, acpSessionID: "ses_test")),
            resumeSessionId: nil)

        vm.send("first")
        vm.send("second")
        XCTAssertEqual(vm.queuedMessages.map(\.text), ["second"])

        vm.handleHostEvent(.turnFinishedWhileDetached(stopReason: "cancelled"))

        XCTAssertFalse(vm.isTurnActive)
        XCTAssertEqual(
            vm.queuedMessages.map(\.text), ["second"],
            "a cancelled detached turn must not auto-release the queue")
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

    func testElicitationPresentAnswerAndTurnEndCancel() throws {
        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        let requestJSON = #"""
        {"mode":"form","sessionId":"ses_test","message":"Pick one",
         "requestedSchema":{"type":"object","properties":{
           "question_0":{"type":"string","oneOf":[{"const":"A"},{"const":"B"}]}}}}
        """#
        let request = try JSONDecoder().decode(
            CreateElicitationRequest.self, from: Data(requestJSON.utf8))

        var received: CreateElicitationResponse?
        vm.presentElicitation(request) { received = $0 }
        XCTAssertEqual(vm.activityState, .awaiting)
        XCTAssertEqual(vm.pendingElicitation?.form?.fields.count, 1)

        // A second concurrent elicitation is defensively cancelled.
        var second: CreateElicitationResponse?
        vm.presentElicitation(request) { second = $0 }
        XCTAssertEqual(second?.action, "cancel")

        vm.respondElicitation(.accept(["question_0": .string("A")]))
        XCTAssertEqual(received?.action, "accept")
        XCTAssertEqual(received?.content?["question_0"]?.stringValue, "A")
        XCTAssertNil(vm.pendingElicitation)
        XCTAssertNotEqual(vm.activityState, .awaiting)

        // An open question dies with its turn.
        var third: CreateElicitationResponse?
        vm.presentElicitation(request) { third = $0 }
        vm.handleConnectionClosed(error: nil)
        XCTAssertEqual(third?.action, "cancel")
        XCTAssertNil(vm.pendingElicitation)
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

    /// Resuming a long session replays the whole conversation as a burst of
    /// `session/update` notifications. They must land in the transcript in ONE
    /// published mutation — appending them one-by-one froze the main thread on
    /// resume. Turns are separated by a tool call (which closes the streams),
    /// mirroring a real replay, so item boundaries are deterministic.
    func testResumeReplaysHistoryInOneItemsMutation() async {
        func upd(_ inner: String) -> String {
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_test","update":\#(inner)}}"#
        }
        let transport = ScriptedAgentTransport()
        var history: [String] = []
        let turns = 20
        for i in 0..<turns {
            history.append(upd(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"q\#(i)"}}"#))
            history.append(upd(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"a\#(i)"}}"#))
            history.append(upd(#"{"sessionUpdate":"tool_call","toolCallId":"c\#(i)","title":"Run","status":"completed"}"#))
        }
        transport.loadUpdates = history

        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()

        var itemsEmissions = 0
        let sub = vm.$items.dropFirst().sink { _ in itemsEmissions += 1 }
        defer { sub.cancel() }

        await vm.bootstrap(connection: connection, resumeSessionId: "ses_test")

        XCTAssertEqual(vm.sessionId, "ses_test")
        // user + agent + tool per turn, in order.
        XCTAssertEqual(vm.items.count, turns * 3)
        XCTAssertEqual((vm.items[0] as! MessageItem).fullText, "q0")
        XCTAssertEqual((vm.items[1] as! MessageItem).fullText, "a0")
        XCTAssertTrue(vm.items[2] is ToolCallItem)
        XCTAssertEqual((vm.items[3] as! MessageItem).fullText, "q1")
        XCTAssertEqual((vm.items[(turns - 1) * 3 + 1] as! MessageItem).fullText, "a\(turns - 1)")
        // The whole history is published in a single mutation, not one per item.
        XCTAssertEqual(itemsEmissions, 1)
        vm.shutdown()
    }

    /// A resumed conversation replays every stored user turn — including the
    /// synthetic ones the agent's harness injected (background-task
    /// notifications, system reminders, slash-command echoes). Those must not
    /// render as user bubbles; only turns the user actually typed survive.
    func testHarnessEnvelopeUserTurnsDroppedOnReplay() async {
        func upd(_ inner: String) -> String {
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_test","update":\#(inner)}}"#
        }
        func user(_ text: String) -> String {
            upd(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"\#(text)"}}"#)
        }
        func agent(_ text: String) -> String {
            upd(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}"#)
        }
        func tool(_ id: String) -> String {
            upd(#"{"sessionUpdate":"tool_call","toolCallId":"\#(id)","title":"Run","status":"completed"}"#)
        }
        let transport = ScriptedAgentTransport()
        transport.loadUpdates = [
            user("real question"), agent("real answer"), tool("c0"),
            user("<task-notification><id>x</id></task-notification>"), tool("c1"),
            user("<system-reminder>be concise</system-reminder>"), tool("c2"),
            user("<command-name>/model</command-name>"), agent("switched"), tool("c3"),
            user("second real"), agent("second answer"),
        ]
        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection, resumeSessionId: "ses_test")

        let userTexts = vm.items.compactMap { item -> String? in
            guard let m = item as? MessageItem, m.role == .user else { return nil }
            return m.fullText
        }
        XCTAssertEqual(userTexts, ["real question", "second real"])
        vm.shutdown()
    }

    /// Consecutive turns with NO tool call between them: [user, agent, user,
    /// agent]. Replay must keep four separate messages IN ORDER. A user chunk
    /// ends the previous agent turn, so the second answer must not merge into
    /// the first bubble — which stranded the second question BELOW its own
    /// answer on resume (the "answer before question" bug). Only a tool call
    /// used to close the agent stream, so tool-less turns merged.
    func testConsecutiveTurnsWithoutToolKeepMessageOrder() async {
        func upd(_ inner: String) -> String {
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_test","update":\#(inner)}}"#
        }
        func user(_ t: String) -> String {
            upd(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"\#(t)"}}"#)
        }
        func agent(_ t: String) -> String {
            upd(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(t)"}}"#)
        }
        let transport = ScriptedAgentTransport()
        transport.loadUpdates = [user("q0"), agent("a0"), user("q1"), agent("a1")]
        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection, resumeSessionId: "ses_test")

        let seq = vm.items.compactMap { item -> String? in
            guard let m = item as? MessageItem else { return nil }
            return "\(m.role == .user ? "U" : "A"):\(m.fullText)"
        }
        XCTAssertEqual(seq, ["U:q0", "A:a0", "U:q1", "A:a1"])
        vm.shutdown()
    }

    /// A retried resume (e.g. the first load raced an error) must rebuild the
    /// transcript, not stack a second copy on top of the first.
    func testResumeReplayReplacesRatherThanAppends() async {
        func upd(_ inner: String) -> String {
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_test","update":\#(inner)}}"#
        }
        let transport = ScriptedAgentTransport()
        transport.loadUpdates = [
            upd(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"only answer"}}"#)
        ]
        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()

        await vm.bootstrap(connection: connection, resumeSessionId: "ses_test")
        XCTAssertEqual(vm.items.count, 1)
        // Resume again against the same stored history — a duplicate would
        // leave two copies; a clean rebuild keeps exactly one.
        await vm.bootstrap(connection: connection, resumeSessionId: "ses_test")
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual((vm.items[0] as! MessageItem).fullText, "only answer")
        vm.shutdown()
    }

    /// Attaching MID-TURN loads the prior conversation IMMEDIATELY — not
    /// deferred to turn end — so a long-running task shows its history the
    /// moment you attach. session/load returns the persisted history as a block
    /// before its response; the pane stays turn-active and keeps streaming the
    /// live turn after.
    func testMidTurnAttachLoadsHistoryImmediately() async {
        func upd(_ inner: String) -> String {
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_test","update":\#(inner)}}"#
        }
        let t = ScriptedAgentTransport()
        // A mid-turn replay ends with the RUNNING turn's own prompt — the
        // newest user message. The turn-active guard must not eat it.
        t.loadUpdates = [
            upd(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"earlier answer"}}"#),
            upd(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"newest question"}}"#)
        ]
        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        let bridge = vm.makeBridge()
        let c = ACPConnection(transport: t, handler: bridge)
        await c.start()
        await vm.bootstrapAttached(
            launch: AgentLaunch(
                connection: c, transport: nil,
                attachInfo: AttachInfo(agentID: "agent-1", running: true,
                                       turnActive: true, acpSessionID: "ses_test")),
            resumeSessionId: nil)
        // History present right away, and the pane stays live (mid-turn).
        XCTAssertTrue(vm.items.contains { ($0 as? MessageItem)?.fullText == "earlier answer" })
        // The trailing user message survived the replay and is closed out.
        let newest = vm.items.compactMap { $0 as? MessageItem }.last { $0.role == .user }
        XCTAssertEqual(newest?.fullText, "newest question")
        XCTAssertEqual(newest?.isStreaming, false)
        XCTAssertTrue(vm.isTurnActive)
        XCTAssertEqual(vm.phase, .ready)
        // A live chunk arriving after the load appends as the current turn.
        vm.handle(chunk("agent_message_chunk", "live tail"))
        XCTAssertEqual((vm.items.last as! MessageItem).fullText, "live tail")
        vm.shutdown()
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

    // MARK: - Restart

    /// A transport DROP (error != nil) on a daemon-hosted agent is a
    /// relay/socket blip — the agent is still alive on the Mac. The client must
    /// enter a reconnecting state and ask the store to reattach, NOT flash
    /// "agent exited". This is the phone-side fix for connections dropping on
    /// every daemon relay reconnect.
    func testTransportDropOnDaemonAgentReconnectsInsteadOfEnding() async {
        let t = ScriptedAgentTransport()
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = vm.makeBridge()
        let c = ACPConnection(transport: t, handler: bridge)
        await c.start()
        var reconnectRequests = 0
        vm.onConnectionLost = { reconnectRequests += 1 }
        await vm.bootstrapAttached(
            launch: AgentLaunch(
                connection: c, transport: nil,
                attachInfo: AttachInfo(agentID: "agent-1", running: true,
                                       turnActive: false, acpSessionID: "ses_test")),
            resumeSessionId: nil)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.agentID, "agent-1")

        await bridge.connectionDidClose(error: ACPError.transportClosed)
        XCTAssertNotEqual(vm.phase, .ended, "a recoverable drop must not end the session")
        XCTAssertTrue(vm.isReconnecting)
        XCTAssertEqual(reconnectRequests, 1, "the store is asked to reattach")
    }

    /// A CLEAN close (error == nil) is a real agent exit (the daemon sent
    /// `exit`) — that stays terminal even with reconnect wired.
    func testCleanCloseOnDaemonAgentStillEnds() async {
        let t = ScriptedAgentTransport()
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = vm.makeBridge()
        let c = ACPConnection(transport: t, handler: bridge)
        await c.start()
        var reconnectRequests = 0
        vm.onConnectionLost = { reconnectRequests += 1 }
        await vm.bootstrapAttached(
            launch: AgentLaunch(
                connection: c, transport: nil,
                attachInfo: AttachInfo(agentID: "agent-1", running: true,
                                       turnActive: false, acpSessionID: "ses_test")),
            resumeSessionId: nil)
        XCTAssertEqual(vm.phase, .ready)

        await bridge.connectionDidClose(error: nil)
        XCTAssertEqual(vm.phase, .ended)
        XCTAssertFalse(vm.isReconnecting)
        XCTAssertEqual(reconnectRequests, 0, "a real exit does not trigger reconnect")
    }

    /// A close carrying an ACPError.malformedMessage must surface its human
    /// text, not the Swift case name — the phone was showing the literal
    /// "malformedMessage(...)" leaked through String(describing:).
    func testMalformedMessageErrorSurfacesCleanText() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        vm.handleConnectionClosed(error: ACPError.malformedMessage("boom happened"))
        XCTAssertEqual(vm.phase, .ended)
        let notice = vm.items.compactMap { $0 as? NoticeItem }.last
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.message.contains("boom happened"))
        XCTAssertFalse(notice!.message.contains("malformedMessage"))
    }

    func testIsStoppedReflectsEndedPhase() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        XCTAssertFalse(vm.isStopped)  // .starting
        vm.handleConnectionClosed(error: nil)
        XCTAssertEqual(vm.phase, .ended)
        XCTAssertTrue(vm.isStopped)
    }

    func testMakeBridgeNeutersPriorConnection() async {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let stale = vm.makeBridge()
        XCTAssertTrue(stale.session === vm)
        let fresh = vm.makeBridge()
        XCTAssertNil(stale.session, "a superseded bridge is detached from the session")
        XCTAssertTrue(fresh.session === vm)
        // A late close arriving on the superseded connection must NOT end the
        // session — this is the guard that stops a restart from being clobbered
        // by the dead connection's trailing teardown callback.
        await stale.connectionDidClose(error: ACPError.transportClosed)
        XCTAssertNotEqual(vm.phase, .ended)
    }

    func testPrepareForRestartReturnsStoppedSessionToStarting() {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        vm.handleConnectionClosed(error: ACPError.transportClosed)
        XCTAssertTrue(vm.isStopped)
        vm.prepareForRestart()
        XCTAssertEqual(vm.phase, .starting)
        XCTAssertFalse(vm.isStopped)
        XCTAssertTrue(vm.queuedMessages.isEmpty)
    }

    /// End-to-end analogue of `AgentWorkspaceStore.restartPane`: a stopped
    /// session is re-established IN PLACE on the same runtime object (so the
    /// bound surface needs no re-attach) and resumes its recorded conversation.
    func testRestartResumesConversationOnSameObject() async {
        func upd(_ inner: String) -> String {
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_test","update":\#(inner)}}"#
        }
        // First life: a fresh session on a scripted agent.
        let t1 = ScriptedAgentTransport()
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let b1 = vm.makeBridge()
        let c1 = ACPConnection(transport: t1, handler: b1)
        await c1.start()
        await vm.bootstrap(connection: c1, resumeSessionId: nil)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.sessionId, "ses_test")

        // The agent dies out from under the client.
        vm.handleConnectionClosed(error: ACPError.transportClosed)
        XCTAssertTrue(vm.isStopped)

        // Restart in place — reset to pre-bootstrap, then re-establish and
        // resume "ses_test". makeBridge runs before any await, so it neuters b1
        // ahead of c1's trailing teardown (mirrors restartPane → establish).
        vm.prepareForRestart()
        let t2 = ScriptedAgentTransport()
        t2.loadUpdates = [
            upd(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"earlier q"}}"#),
            upd(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"earlier a"}}"#),
        ]
        let b2 = vm.makeBridge()
        let c2 = ACPConnection(transport: t2, handler: b2)
        await c2.start()
        await vm.bootstrap(connection: c2, resumeSessionId: "ses_test")
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.sessionId, "ses_test")
        // The recorded conversation replayed back through session/load.
        let texts = vm.items.compactMap { ($0 as? MessageItem)?.fullText }
        XCTAssertTrue(texts.contains("earlier q"))
        XCTAssertTrue(texts.contains("earlier a"))

        // A trailing close from the FIRST (dead) connection is now ignored.
        await b1.connectionDidClose(error: ACPError.transportClosed)
        XCTAssertEqual(vm.phase, .ready)
    }
}
