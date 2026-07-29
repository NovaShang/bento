import ACPKit
import XCTest

@testable import BentoCore

/// What a SECOND viewer of the same agent sees. Everything here used to be
/// inferable only by the client that happened to drive the agent itself.
@MainActor
final class MultiViewerStateTests: XCTestCase {
    private func makeVM() -> AgentSessionViewModel {
        AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
    }

    /// A VM that reached `.ready` through the normal bootstrap, which is what
    /// the turn-state guard requires.
    private func makeReadyVM() async -> AgentSessionViewModel {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: ScriptedAgentTransport(), handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection)
        return vm
    }

    private func permissionRequest(_ tool: String) -> RequestPermissionRequest {
        let json = """
        {"sessionId":"ses_test","toolCall":{"toolCallId":"\(tool)","title":"Run \(tool)"},\
        "options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},\
        {"optionId":"deny","name":"Deny","kind":"reject_once"}]}
        """
        return try! JSONDecoder().decode(RequestPermissionRequest.self, from: Data(json.utf8))
    }

    // MARK: - Turn state

    /// A turn started by another device makes this pane show WORKING. Before
    /// the daemon broadcast this, the co-viewer stayed idle while output
    /// streamed in.
    func testTurnStartedElsewhereMakesThePaneWorking() async {
        let vm = await makeReadyVM()
        XCTAssertFalse(vm.isTurnActive)
        XCTAssertEqual(vm.activityState, .idle)

        vm.handleHostEvent(.turnStartedElsewhere)

        XCTAssertTrue(vm.isTurnActive)
        XCTAssertEqual(vm.activityState, .working)
    }

    /// And it still ends on the turnDone this pane already knew how to read,
    /// so the two halves close over each other.
    func testTurnStartedElsewhereEndsOnTurnDone() async {
        let vm = await makeReadyVM()
        vm.handleHostEvent(.turnStartedElsewhere)
        vm.handleHostEvent(.turnFinishedWhileDetached(stopReason: "end_turn"))
        XCTAssertFalse(vm.isTurnActive)
    }

    // MARK: - Approvals

    /// The ghost card: answered on the other device, so nothing else will
    /// ever mention this request again. It has to go on the broadcast alone.
    func testRequestAnsweredElsewhereClearsTheCard() async {
        // A ready VM, so the states either side of the card are meaningful
        // (a VM still in `.starting` reads as working no matter what).
        let vm = await makeReadyVM()
        var localOutcome: RequestPermissionOutcome?
        vm.presentPermission(permissionRequest("t1")) { localOutcome = $0 }
        XCTAssertNotNil(vm.pendingPermission)
        XCTAssertEqual(vm.activityState, .awaiting)

        vm.handleHostEvent(.agentRequestAnswered(requestID: "1"))

        XCTAssertNil(vm.pendingPermission, "the card someone else answered must disappear")
        XCTAssertEqual(vm.activityState, .idle)
        // The suspended handler is released — otherwise the connection's
        // request task never finishes.
        XCTAssertEqual(localOutcome, .cancelled)
    }

    /// The dangerous default: a second request used to be auto-declined
    /// because the first was still up. With a stale card that made this
    /// device deny requests a human was answering on the other one — and the
    /// daemon takes the FIRST answer.
    func testSecondRequestIsQueuedNotDeclined() {
        let vm = makeVM()
        var first: RequestPermissionOutcome?
        var second: RequestPermissionOutcome?
        vm.presentPermission(permissionRequest("t1")) { first = $0 }
        vm.presentPermission(permissionRequest("t2")) { second = $0 }

        XCTAssertNil(second, "the second request must not be answered on arrival")
        XCTAssertEqual(vm.pendingPermission?.request.toolCall.toolCallId, "t1")

        vm.respondPermission(.selected(optionId: "allow"))
        XCTAssertEqual(first, .selected(optionId: "allow"))
        XCTAssertEqual(vm.pendingPermission?.request.toolCall.toolCallId, "t2",
                       "answering the head reveals the one behind it")
        XCTAssertNil(second)

        vm.respondPermission(.selected(optionId: "deny"))
        XCTAssertEqual(second, .selected(optionId: "deny"))
        XCTAssertNil(vm.pendingPermission)
    }

    /// Permissions and elicitations share one queue because the daemon has
    /// one: only the head is shown, whichever kind it is.
    func testPromptsOfBothKindsShareOneQueue() {
        let vm = makeVM()
        let elicitation = try! JSONDecoder().decode(
            CreateElicitationRequest.self,
            from: Data(#"{"sessionId":"ses_test","message":"Which one?","mode":"form"}"#.utf8))

        vm.presentPermission(permissionRequest("t1")) { _ in }
        vm.presentElicitation(elicitation) { _ in }

        XCTAssertNotNil(vm.pendingPermission)
        XCTAssertNil(vm.pendingElicitation, "only the head is shown")

        vm.respondPermission(.cancelled)
        XCTAssertNil(vm.pendingPermission)
        XCTAssertNotNil(vm.pendingElicitation, "the elicitation behind it surfaces")
    }

    // MARK: - Reconnect

    /// A load whose replay never arrives — answered from the daemon's cache,
    /// or suppressed — must not blank a pane that already has history. This
    /// is the belt on the whole class: it wiped eight real panes at once.
    func testEmptyReplayDoesNotBlankAnExistingTranscript() async {
        let vm = await makeReadyVM()
        vm.handle(sessionNote(seq: 1, text: "history"))
        XCTAssertEqual(vm.items.count, 1)

        vm.replayProducingNothingForTests()

        XCTAssertEqual(vm.items.count, 1, "an empty replay must not replace a good transcript")
    }

    /// But a genuine load of an empty conversation still publishes empty.
    func testEmptyReplayOnAnEmptyPaneIsFine() async {
        let vm = await makeReadyVM()
        vm.replayProducingNothingForTests()
        XCTAssertTrue(vm.items.isEmpty)
    }

    /// `seq` is deliberately off the wire format — ACPConnection stamps it
    /// after decoding, which is the whole point: it tracks what has been
    /// APPLIED, not what has been delivered.
    private func sessionNote(seq: UInt64, text: String) -> SessionNotification {
        let json = #"{"sessionId":"ses_test","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"TEXT"}}}"#
            .replacingOccurrences(of: "TEXT", with: text)
        var note = try! JSONDecoder().decode(SessionNotification.self, from: Data(json.utf8))
        note.seq = seq
        return note
    }

    /// A cancelled turn answers every outstanding request, not just the one
    /// on screen — the spec requires the agent to see a response for each.
    func testCancelAnswersTheWholeQueue() {
        let vm = makeVM()
        var outcomes: [RequestPermissionOutcome] = []
        vm.presentPermission(permissionRequest("t1")) { outcomes.append($0) }
        vm.presentPermission(permissionRequest("t2")) { outcomes.append($0) }

        vm.handleConnectionClosed(error: nil)

        XCTAssertEqual(outcomes, [.cancelled, .cancelled])
        XCTAssertNil(vm.pendingPermission)
    }
}
