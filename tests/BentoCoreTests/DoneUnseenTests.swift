import XCTest
@testable import BentoCore

/// The pure "done, unseen" (green ✓) transition. The regression this locks in:
/// a reconnect settles panes from a `.starting`-induced `.working` back to
/// idle, and that settle must NOT flash every unfocused idle pane green.
@MainActor
final class DoneUnseenTests: XCTestCase {

    // A genuine turn finishing while unfocused earns the badge.
    func testRealTurnFinishEarnsBadge() {
        // Turn running: working, real work seen, not settling → no badge yet.
        XCTAssertFalse(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .working,
            isSettling: false, didRealWork: true, prev: false))
        // Turn ends → idle: real work happened → GREEN.
        XCTAssertTrue(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .idle,
            isSettling: false, didRealWork: true, prev: false))
    }

    // Awaiting-input, then resolving to idle, also earns the badge.
    func testAwaitingThenIdleEarnsBadge() {
        XCTAssertTrue(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .idle,
            isSettling: false, didRealWork: true, prev: false))
    }

    // THE BUG: a reconnect settle (was idle-and-seen) must stay gray.
    func testReconnectSettleDoesNotFlashGreen() {
        // While reattaching the pane reads working, but it is settling → stays
        // as it was (not seen → not green).
        XCTAssertFalse(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .working,
            isSettling: true, didRealWork: false, prev: false))
        // Settles to idle having done no real work → still gray.
        XCTAssertFalse(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .idle,
            isSettling: false, didRealWork: false, prev: false))
    }

    // A fresh spawn that lands idle while unfocused must also stay gray.
    func testFreshSpawnDoesNotFlashGreen() {
        XCTAssertFalse(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .idle,
            isSettling: false, didRealWork: false, prev: false))
    }

    // A pane that WAS green keeps its badge across a reconnect blip.
    func testReconnectPreservesExistingBadge() {
        // Reconnect shimmer is transparent → keeps prev.
        XCTAssertTrue(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .working,
            isSettling: true, didRealWork: false, prev: true))
        // Settled idle, no new work → memory retained.
        XCTAssertTrue(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .idle,
            isSettling: false, didRealWork: false, prev: true))
    }

    // Focusing the pane clears the badge; staying idle keeps it.
    func testFocusClearsAndIdleKeeps() {
        XCTAssertFalse(WorkspaceViewModel.doneUnseen(
            isFocused: true, newState: .idle,
            isSettling: false, didRealWork: true, prev: true))
        XCTAssertTrue(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .idle,
            isSettling: false, didRealWork: false, prev: true))
    }

    // Starting a genuinely new turn (working, not settling) clears a stale badge.
    func testNewTurnClearsStaleBadge() {
        XCTAssertFalse(WorkspaceViewModel.doneUnseen(
            isFocused: false, newState: .working,
            isSettling: false, didRealWork: true, prev: true))
    }
}
