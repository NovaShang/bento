import XCTest
@testable import BentoShellTermMac

// The resize-storm regression suite. On the trunk one daemon-side control
// client carries the whole session, so a client-size declaration RESIZES tmux
// (reflowing every pane, redrawing every fullscreen TUI) instead of merely
// announcing one client's viewport the way the frozen per-window tmux client
// did. These tests pin the two properties that keep declarations scarce.
final class ViewportDeclarationGateTests: XCTestCase {

    func testIdenticalGridIsDeclaredOnce() {
        var gate = ViewportDeclarationGate()
        XCTAssertNotNil(gate.offer(cols: 207, rows: 47))
        // The mirror re-publishes on every structural hop and each hop re-runs
        // layout: without dedup a Focus↔Parallel reshape declares per hop.
        for _ in 0..<10 {
            XCTAssertNil(gate.offer(cols: 207, rows: 47))
        }
        XCTAssertNotNil(gate.offer(cols: 207, rows: 48), "a real change must go out")
    }

    func testForceReassertsAnUnchangedGrid() {
        var gate = ViewportDeclarationGate()
        XCTAssertNotNil(gate.offer(cols: 180, rows: 48))
        XCTAssertNil(gate.offer(cols: 180, rows: 48))
        // "Fit session to this window" / claiming the pin: another device may
        // have shrunk the session, so an unchanged grid must still be sent.
        XCTAssertNotNil(gate.offer(cols: 180, rows: 48, force: true))
    }

    /// The exact limit cycle from the daemon log: two formulas differing by the
    /// title-bar row (`181x47` window grid ↔ `158x48` tmux-derived surface
    /// grid) alternating forever. The formula fix means only one of them can be
    /// offered now; the gate is the second line of defence — it must not let an
    /// alternation ping-pong indefinitely without a real change behind it.
    func testAlternationCollapsesOnceItStops() {
        var gate = ViewportDeclarationGate()
        var declared = 0
        for i in 0..<12 {
            let grid = i.isMultiple(of: 2) ? (181, 47) : (158, 48)
            if gate.offer(cols: grid.0, rows: grid.1) != nil { declared += 1 }
        }
        XCTAssertEqual(declared, 12, "each differing value is a genuine offer")
        // Once the source settles on one value, the wire goes quiet: the first
        // offer after the alternation is still a change, everything after is not.
        XCTAssertNotNil(gate.offer(cols: 181, rows: 47))
        for _ in 0..<10 { XCTAssertNil(gate.offer(cols: 181, rows: 47)) }
    }

    func testTransitionHoldsDeclarationsAndEmitsTheLastOne() {
        var gate = ViewportDeclarationGate()
        XCTAssertNotNil(gate.offer(cols: 207, rows: 47))

        gate.beginTransition()
        // Intermediate structures the reshape walks through (break-pane /
        // join-pane, one pane at a time) plus the sidebar collapsing under it.
        XCTAssertNil(gate.offer(cols: 158, rows: 48))
        XCTAssertNil(gate.offer(cols: 180, rows: 48))
        XCTAssertNil(gate.offer(cols: 180, rows: 47))
        let settled = gate.endTransition()
        XCTAssertEqual(settled?.cols, 180)
        XCTAssertEqual(settled?.rows, 47, "only the last, settled grid goes out")
        XCTAssertNil(gate.offer(cols: 180, rows: 47), "and it now stands")
    }

    func testTransitionThatChangesNothingDeclaresNothing() {
        var gate = ViewportDeclarationGate()
        XCTAssertNotNil(gate.offer(cols: 207, rows: 47))
        gate.beginTransition()
        XCTAssertNil(gate.offer(cols: 158, rows: 48))
        XCTAssertNil(gate.offer(cols: 207, rows: 47))
        XCTAssertNil(gate.endTransition(), "back where it started — nothing to say")
    }

    func testNestedTransitionsHoldUntilTheOutermostSettles() {
        var gate = ViewportDeclarationGate()
        gate.beginTransition()
        gate.beginTransition()
        XCTAssertNil(gate.offer(cols: 100, rows: 30))
        XCTAssertNil(gate.endTransition(), "inner settle is not the settle point")
        XCTAssertNotNil(gate.endTransition())
    }

    func testForcePassesEvenMidTransition() {
        var gate = ViewportDeclarationGate()
        gate.beginTransition()
        XCTAssertNotNil(gate.offer(cols: 120, rows: 40, force: true),
                        "a user-initiated refit is never noise")
    }

    func testZeroAndNegativeGridsAreRefused() {
        var gate = ViewportDeclarationGate()
        XCTAssertNil(gate.offer(cols: 0, rows: 40))
        XCTAssertNil(gate.offer(cols: 120, rows: 0))
        XCTAssertNil(gate.offer(cols: -5, rows: -5, force: true))
        XCTAssertNil(gate.standing.map { _ in true })
    }

    func testInvalidateLetsTheSameGridGoOutAgain() {
        var gate = ViewportDeclarationGate()
        XCTAssertNotNil(gate.offer(cols: 313, rows: 78))
        XCTAssertNil(gate.offer(cols: 313, rows: 78))
        // The control channel dropped: the daemon no longer holds this stream's
        // viewport, so what "stands" is a lie until it's re-declared.
        gate.invalidate()
        XCTAssertNotNil(gate.offer(cols: 313, rows: 78))
    }
}
