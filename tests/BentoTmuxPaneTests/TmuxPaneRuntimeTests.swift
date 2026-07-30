import XCTest
import BentoTerminalPane
import BentoWorkbench
@testable import BentoTmuxPane

/// The blueprint's PaneRuntime mapping table, verified over the in-memory
/// transport: send-keys semantics (send = bytes + CR, insert = bytes),
/// the empty draft box, attach/exit phase transitions, the wire-unit
/// cursor, and the output-parse state language.
@MainActor
final class TmuxPaneRuntimeTests: XCTestCase {
    private var transport: InMemoryTmuxTransport!
    private var runtime: TmuxPaneRuntime!

    override func setUp() {
        transport = InMemoryTmuxTransport()
        runtime = TmuxPaneRuntime(
            instanceID: TmuxVirtualInstanceID(target: "local", pane: TmuxPaneID(5)),
            title: "zsh",
            transport: transport)
    }

    override func tearDown() {
        runtime.shutdown()
    }

    /// Poll until `condition` holds (the attach task hops the main actor).
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Input (send-keys semantics)

    func testSendAppendsCR() {
        runtime.send("ls -la")
        XCTAssertEqual(transport.writtenText, "ls -la\r")
    }

    func testInsertIntoComposerDoesNotAppendCR() {
        runtime.insertIntoComposer("git sta")
        XCTAssertEqual(transport.writtenText, "git sta")
    }

    func testRawWritePassesBytesThrough() {
        runtime.write(Data([0x1b, 0x5b, 0x41]))   // an arrow key, verbatim
        XCTAssertEqual(transport.written, [Data([0x1b, 0x5b, 0x41])])
    }

    func testComposerDraftIsAlwaysEmpty() {
        XCTAssertEqual(runtime.composerDraft, "")
        runtime.composerDraft = "never lands"
        XCTAssertEqual(runtime.composerDraft, "")
        XCTAssertTrue(transport.written.isEmpty)   // and never leaks as bytes
    }

    func testResizeForwardsRendererGrid() {
        runtime.resize(cols: 120, rows: 40)
        XCTAssertEqual(transport.resizes.count, 1)
        XCTAssertEqual(transport.resizes[0].cols, 120)
        XCTAssertEqual(transport.resizes[0].rows, 40)
    }

    // MARK: - Phase (attach / exit)

    func testAttachReachesReady() async {
        XCTAssertEqual(runtime.phase, .starting)
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        XCTAssertEqual(runtime.phase, .ready)
        XCTAssertEqual(transport.attaches, [0])   // cold cursor
    }

    func testAttachToExitedPaneEndsImmediately() async {
        transport.running = false
        runtime.attach()
        await waitUntil { self.runtime.phase == .ended }
        XCTAssertEqual(runtime.phase, .ended)
    }

    func testExitEventEndsPhase() async {
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        transport.push(.exit(code: 0, message: nil))
        await waitUntil { self.runtime.phase == .ended }
        XCTAssertEqual(runtime.phase, .ended)
    }

    func testAttachFailureFailsPhase() async {
        transport.attachError = NSError(domain: "test", code: 1)
        runtime.attach()
        await waitUntil {
            if case .failed = self.runtime.phase { return true }
            return false
        }
        guard case .failed = runtime.phase else {
            return XCTFail("expected .failed, got \(runtime.phase)")
        }
    }

    func testPrepareForRestartReturnsToStarting() async {
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        runtime.prepareForRestart()
        XCTAssertEqual(runtime.phase, .starting)
    }

    // MARK: - Wire death (daemon restart survival)

    /// A stream that ends WITHOUT an exit frame is a dead wire, not a dead
    /// pane: the runtime must re-attach on its own, cursor preserved — the
    /// daemon-restart freeze (GUI zombie until app relaunch) regression.
    func testWireDeathReattachesWithPreservedCursor() async {
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        transport.pushOutput("a")
        transport.pushOutput("b")
        await waitUntil { self.runtime.updateSeq == 2 }

        transport.dropConnection()
        await waitUntil(timeout: 4) { self.transport.attaches.count == 2 }
        XCTAssertEqual(transport.attaches, [0, 2])   // cursor carried over
        await waitUntil { self.runtime.phase == .ready }
        XCTAssertEqual(runtime.phase, .ready)

        // The re-attached stream is live: output flows again.
        transport.pushOutput("c")
        await waitUntil { self.runtime.updateSeq == 3 }
        XCTAssertEqual(runtime.updateSeq, 3)
    }

    /// An exit frame is a real pane death — the runtime must NOT treat the
    /// stream end that follows it as a dead wire and re-attach.
    func testExitDoesNotTriggerReattach() async {
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        transport.push(.exit(code: 0, message: nil))
        await waitUntil { self.runtime.phase == .ended }
        // Give the (would-be) retry backoff a chance to fire wrongly.
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(transport.attaches.count, 1)
        XCTAssertEqual(runtime.phase, .ended)
    }

    // MARK: - Catch-up cursor (wire units)

    func testLiveAttachAdoptsHeadSeqAndCountsUnits() async {
        transport.headSeq = 42
        transport.replay = false
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        XCTAssertEqual(runtime.updateSeq, 42)   // live-from-head, gap not resent
        transport.pushOutput("hello")
        await waitUntil { self.runtime.updateSeq == 43 }
        XCTAssertEqual(runtime.updateSeq, 43)
        XCTAssertTrue(runtime.holdsRenderedTranscript)
    }

    func testReplayAttachCountsFromOwnCursor() async {
        transport.headSeq = 2
        transport.replay = true
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        XCTAssertEqual(runtime.updateSeq, 0)   // the daemon resends the tail
        transport.pushOutput("a")
        transport.pushOutput("b")
        await waitUntil { self.runtime.updateSeq == 2 }
        XCTAssertEqual(runtime.updateSeq, 2)
    }

    func testOutputReachesSurfaceCallback() async {
        var fed: [Data] = []
        runtime.onOutput = { fed.append($0) }
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        transport.pushOutput("bytes")
        await waitUntil { !fed.isEmpty }
        XCTAssertEqual(fed, [Data("bytes".utf8)])
    }

    // MARK: - State language (legacy output-parse rules, non-agent panes)

    func testRecentOutputReadsAsWorking() async {
        runtime.attach()   // no recognized agent command: legacy recency path
        await waitUntil { self.runtime.phase == .ready }
        transport.pushOutput("Compiling module 3 of 7…\n")
        await waitUntil { self.runtime.isTurnActive }
        XCTAssertTrue(runtime.isTurnActive)
        XCTAssertFalse(runtime.isAwaitingUserInput)
    }

    // MARK: - Agent rule engine (the frozen classifyPane ladder)

    /// A braille spinner title resolves .working on the cheap pass — no
    /// screen capture round trip.
    func testSpinnerTitleReadsWorkingWithoutSnapshot() async {
        runtime.currentCommand = "claude"
        runtime.title = "⠋ 编译计划中"
        nonisolated(unsafe) var captured = false
        runtime.captureScreenText = { captured = true; return nil }
        await runtime.refreshAgentState()
        XCTAssertTrue(runtime.isTurnActive)
        XCTAssertFalse(captured)
    }

    /// The ✳ at-rest title reads idle even while output is arriving — the
    /// regression where every idle claude pane lit "working" because only
    /// output recency was consulted.
    func testIdleMarkerTitleReadsIdleDespiteRecentOutput() async {
        runtime.currentCommand = "claude"
        runtime.title = "✳ 优化订阅策略"
        runtime.captureScreenText = { "tokens used: 12345" }
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        transport.pushOutput("a live repaint\n")   // recency alone would say working
        await waitUntil { self.runtime.updateSeq == 1 }
        await runtime.refreshAgentState()
        XCTAssertFalse(runtime.isTurnActive)
        XCTAssertFalse(runtime.isAwaitingUserInput)
    }

    /// A recognized agent's state belongs to the rule engine alone: live
    /// output must not flip it working between engine ticks.
    func testAgentOutputDoesNotTriggerLegacyRecency() async {
        runtime.currentCommand = "claude"
        runtime.title = "✳ resting"
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        transport.pushOutput("chatter\n")
        await waitUntil { self.runtime.updateSeq == 1 }
        XCTAssertFalse(runtime.isTurnActive)
    }

    func testPermissionFormReadsAsAwaiting() async {
        runtime.currentCommand = "claude"
        runtime.title = "✳ waiting on you"
        runtime.captureScreenText = { """
            Do you want to proceed?
            ❯ 1. Yes
              2. No
            """ }
        await runtime.refreshAgentState()
        XCTAssertTrue(runtime.isAwaitingUserInput)
        XCTAssertFalse(runtime.isTurnActive)
    }

    /// An attach's catch-up replay is history: it must feed the surface and
    /// the text buffer without lighting the pane "working".
    func testReplayDoesNotCountAsActivity() async {
        transport.pushOutput("old line 1\n")   // queued: delivered as the replay
        transport.pushOutput("old line 2\n")
        transport.pushOutput("old line 3\n")
        transport.headSeq = 3
        transport.replay = true
        runtime.attach()
        await waitUntil { self.runtime.updateSeq == 3 }
        XCTAssertFalse(runtime.isTurnActive)   // history stayed history

        transport.pushOutput("live output\n")  // past the boundary: real activity
        await waitUntil { self.runtime.isTurnActive }
        XCTAssertTrue(runtime.isTurnActive)
    }

    func testDoneEdgeSetsHasCompletedTurn() {
        XCTAssertFalse(runtime.hasCompletedTurn)
        runtime.applyDetectedState(.working)
        XCTAssertFalse(runtime.hasCompletedTurn)
        runtime.applyDetectedState(.idle)          // working → idle: the done edge
        XCTAssertTrue(runtime.hasCompletedTurn)
    }

    func testBlockedIsNotAConcludedTurn() {
        runtime.applyDetectedState(.working)
        runtime.applyDetectedState(.awaitingInput(profile: "claude-code"))
        XCTAssertFalse(runtime.hasCompletedTurn)   // blocked mid-turn ≠ done
    }

    func testExitDoesNotFireDoneEdge() async {
        runtime.attach()
        await waitUntil { self.runtime.phase == .ready }
        runtime.applyDetectedState(.working)
        transport.push(.exit(code: 1, message: "died"))
        await waitUntil { self.runtime.phase == .ended }
        XCTAssertFalse(runtime.hasCompletedTurn)   // dying mid-turn ≠ done
        XCTAssertFalse(runtime.isTurnActive)
    }

    // MARK: - Fixed identity answers

    func testTmuxPanesHaveNoAcpIdentity() {
        XCTAssertNil(runtime.sessionTitle)
        XCTAssertNil(runtime.sessionId)
        XCTAssertNil(runtime.firstUserPromptPreview)
    }

    func testShutdownDetaches() {
        runtime.shutdown()
        XCTAssertEqual(transport.detachCount, 1)
    }

    // MARK: - Virtual instance ids

    func testVirtualIDParsesFromTheRight() {
        let local = TmuxVirtualInstanceID(raw: "tmux:local:%5")
        XCTAssertEqual(local?.target, "local")
        XCTAssertEqual(local?.pane, TmuxPaneID(5))
        XCTAssertEqual(local?.raw, "tmux:local:%5")

        // A future ssh target keeps its own colons; the pane never has one.
        let ssh = TmuxVirtualInstanceID(raw: "tmux:ssh://user@host:22:%3")
        XCTAssertEqual(ssh?.target, "ssh://user@host:22")
        XCTAssertEqual(ssh?.pane, TmuxPaneID(3))
    }

    func testVirtualIDRejectsMalformedIds() {
        XCTAssertNil(TmuxVirtualInstanceID(raw: "acp:local:%5"))
        XCTAssertNil(TmuxVirtualInstanceID(raw: "tmux:%5"))
        XCTAssertNil(TmuxVirtualInstanceID(raw: "tmux:local:5"))
        XCTAssertNil(TmuxVirtualInstanceID(raw: "tmux::%5"))
    }
}
