import XCTest
@testable import BentoTerminalCore

/// Deterministic tests for the scroll-review-compose state machine (the
/// logic-heavy part, where the tricky Ctrl-C / commit / esc transitions live).
@MainActor
final class ScrollReviewComposeTests: XCTestCase {

    private func make() -> (ScrollReviewCompose, Recorder) {
        let c = ScrollReviewCompose()
        let r = Recorder()
        c.onInject = { text, exec in r.injects.append((text, exec)) }
        c.onSnapToBottom = { r.snaps += 1 }
        c.onChange = { r.changes += 1 }
        return (c, r)
    }

    final class Recorder {
        var injects: [(String, Bool)] = []
        var snaps = 0
        var changes = 0
    }

    // MARK: scroll → phase

    func testScrollUpEntersReviewIdleAndBackToLive() {
        let (c, _) = make()
        XCTAssertEqual(c.phase, .live)
        c.scrollChanged(atBottom: false)
        XCTAssertEqual(c.phase, .reviewIdle)
        c.scrollChanged(atBottom: true)
        XCTAssertEqual(c.phase, .live)
    }

    func testScrollDrivenTransitionsRefreshUI() {
        // Regression: scroll-only transitions (no edit) must still refresh the
        // bar, or the idle hint never shows and the bar won't close at bottom.
        let (c, r) = make()
        c.scrollChanged(atBottom: false)              // live → reviewIdle (show hint)
        XCTAssertGreaterThan(r.changes, 0)
        let afterIdle = r.changes
        c.scrollChanged(atBottom: true)               // reviewIdle → live (hide bar)
        XCTAssertGreaterThan(r.changes, afterIdle)
        XCTAssertEqual(c.phase, .live)
    }

    func testTypeThenEmptyThenScrollBottomClosesBar() {
        // Repro of the reported bug: type (→draft), delete empty (→idle), scroll
        // to bottom must return to live and refresh so the bar hides.
        let (c, r) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("a")
        c.backspace()                                 // draft empty → reviewIdle
        XCTAssertEqual(c.phase, .reviewIdle)
        let before = r.changes
        c.scrollChanged(atBottom: true)               // scroll to bottom
        XCTAssertEqual(c.phase, .live)
        XCTAssertGreaterThan(r.changes, before, "must refresh so the bar closes")
    }

    func testRepeatedScrollUpStaysReviewIdle() {
        let (c, _) = make()
        c.scrollChanged(atBottom: false)
        c.scrollChanged(atBottom: false)
        XCTAssertEqual(c.phase, .reviewIdle)
    }

    // MARK: typing → draft

    func testInsertTextEntersDraftAndAccumulates() {
        let (c, r) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("h"); c.insertText("i")
        XCTAssertEqual(c.phase, .reviewDraft)
        XCTAssertEqual(c.draftText, "hi")
        XCTAssertTrue(r.injects.isEmpty, "typing must not inject")
    }

    func testInsertTextIgnoredWhenLive() {
        let (c, _) = make()
        c.insertText("x")
        XCTAssertEqual(c.phase, .live)
        XCTAssertEqual(c.draftText, "")
    }

    // MARK: commit

    func testCommitInjectsWithoutExecuteAndReturnsLive() {
        let (c, r) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("ls -la")
        c.commit(execute: false)
        XCTAssertEqual(r.injects.count, 1)
        XCTAssertEqual(r.injects.first?.0, "ls -la")
        XCTAssertEqual(r.injects.first?.1, false)
        XCTAssertEqual(r.snaps, 1)
        XCTAssertEqual(c.phase, .live)
        XCTAssertEqual(c.draftText, "")
    }

    func testCommitExecuteSetsFlag() {
        let (c, r) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("make")
        c.commit(execute: true)
        XCTAssertEqual(r.injects.first?.1, true)
    }

    func testEmptyCommitSnapsButDoesNotInject() {
        let (c, r) = make()
        c.scrollChanged(atBottom: false)   // idle, empty
        c.commit(execute: false)
        XCTAssertTrue(r.injects.isEmpty)
        XCTAssertEqual(r.snaps, 1)
        XCTAssertEqual(c.phase, .live)
    }

    // MARK: scroll-to-bottom hands off a draft

    func testScrollToBottomWithDraftCommits() {
        let (c, r) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("hello")
        c.scrollChanged(atBottom: true)        // user scrolled back down
        XCTAssertEqual(r.injects.first?.0, "hello")
        XCTAssertEqual(r.injects.first?.1, false)
        XCTAssertEqual(c.phase, .live)
    }

    // MARK: control-key passthrough must NOT auto-commit on the snap

    func testCancelForPassthroughDiscardsThenSnapDoesNotCommit() {
        let (c, r) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("rm -rf /")            // dangerous draft in flight
        c.cancelForPassthrough()            // e.g. user hit Ctrl-C
        XCTAssertEqual(c.phase, .live)
        XCTAssertEqual(c.draftText, "")
        c.scrollChanged(atBottom: true)     // the snap the control key caused
        XCTAssertTrue(r.injects.isEmpty, "a control-key snap must never inject the draft")
    }

    // MARK: esc

    func testEscClearsDraftToIdleThenExits() {
        let (c, r) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("abc")
        c.escape()                          // first esc: clear draft
        XCTAssertEqual(c.phase, .reviewIdle)
        XCTAssertEqual(c.draftText, "")
        XCTAssertTrue(r.injects.isEmpty)
        c.escape()                          // second esc: leave review
        XCTAssertEqual(c.phase, .live)
        XCTAssertEqual(r.snaps, 1)
    }

    // MARK: editing

    func testCaretMovementAndBackspace() {
        let (c, _) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("abd")
        c.moveLeft()                        // caret between b and d
        c.insertText("c")                   // -> "abcd"
        XCTAssertEqual(c.draftText, "abcd")
        c.moveRight()                       // caret at end
        c.backspace()                       // -> "abc"
        XCTAssertEqual(c.draftText, "abc")
    }

    func testBackspaceToEmptyReturnsToIdle() {
        let (c, _) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("a")
        XCTAssertEqual(c.phase, .reviewDraft)
        c.backspace()
        XCTAssertEqual(c.phase, .reviewIdle)
        XCTAssertEqual(c.draftText, "")
    }

    func testNewlineKeepsDraftMultiline() {
        let (c, _) = make()
        c.scrollChanged(atBottom: false)
        c.insertText("a"); c.newline(); c.insertText("b")
        XCTAssertEqual(c.draftText, "a\nb")
    }

    // MARK: IME preedit

    func testPreeditShownButNotPartOfDraftUntilCommitted() {
        let (c, _) = make()
        c.scrollChanged(atBottom: false)
        c.setPreedit("ni")                  // composing pinyin
        XCTAssertEqual(c.phase, .reviewDraft)
        XCTAssertEqual(c.draftText, "")     // preedit not yet in draft
        XCTAssertEqual(c.preedit, "ni")
        c.insertText("你")                   // candidate chosen
        XCTAssertEqual(c.draftText, "你")
        XCTAssertEqual(c.preedit, "")
    }

    // MARK: feature flag

    func testDisabledNeverLeavesLive() {
        let (c, r) = make()
        c.isEnabled = false
        c.scrollChanged(atBottom: false)
        c.insertText("x")
        XCTAssertEqual(c.phase, .live)
        XCTAssertTrue(r.injects.isEmpty)
    }
}
