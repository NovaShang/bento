import XCTest
@testable import BentoShellTermMac

/// The declaration arithmetic, pinned. Two properties matter and they pull in
/// opposite directions, which is how the resize storm was born:
///
///  * Focus must FILL: subtracting a title-bar row there left the frozen
///    product's full-area Focus one row short.
///  * The value must never depend on a tmux-derived grid, or the declaration
///    becomes a function of the size it just caused (the 181×47 ↔ 158×48 limit
///    cycle in the daemon log).
///
/// Chrome presence satisfies both: it is a function of TOPOLOGY, and a client
/// size cannot move panes between windows.
final class WindowGridDeclarationTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 17)

    func testFocusFillsTheWindowWithNoChromeRow() {
        // 1600×850 px at 8×17 = 200×50 cells exactly.
        let grid = GhosttyTiledPaneHost.grid(
            windowPx: CGSize(width: 1600, height: 850), cellPx: cell, chromeRows: 0)
        XCTAssertEqual(grid.cols, 200)
        XCTAssertEqual(grid.rows, 50, "Focus draws no title bar — the terminal owns every row")
    }

    func testParallelSpendsExactlyOneRowOnTheTitleBar() {
        let grid = GhosttyTiledPaneHost.grid(
            windowPx: CGSize(width: 1600, height: 850), cellPx: cell, chromeRows: 1)
        XCTAssertEqual(grid.cols, 200)
        XCTAssertEqual(grid.rows, 49, "the top pane's title bar costs one cell row")
    }

    /// The two modes differ by exactly the chrome row — the fingerprint that
    /// identified the storm's two competing formulas. Same window, so cols never
    /// move.
    func testModesDifferByExactlyTheChromeRow() {
        let focus = GhosttyTiledPaneHost.grid(
            windowPx: CGSize(width: 1448, height: 816), cellPx: cell, chromeRows: 0)
        let parallel = GhosttyTiledPaneHost.grid(
            windowPx: CGSize(width: 1448, height: 816), cellPx: cell, chromeRows: 1)
        XCTAssertEqual(focus.cols, parallel.cols)
        XCTAssertEqual(focus.rows - parallel.rows, 1)
    }

    /// Only the window's own pixels and its chrome enter the formula: given both,
    /// the answer is fixed no matter what the mirror says a pane's geometry is.
    func testGridIsAFunctionOfWindowPixelsAndChromeAlone() {
        let a = GhosttyTiledPaneHost.grid(
            windowPx: CGSize(width: 1000, height: 500), cellPx: cell, chromeRows: 1)
        let b = GhosttyTiledPaneHost.grid(
            windowPx: CGSize(width: 1000, height: 500), cellPx: cell, chromeRows: 1)
        XCTAssertEqual(a.cols, b.cols)
        XCTAssertEqual(a.rows, b.rows)
    }

    func testDegenerateInputsStayLegal() {
        let zeroCell = GhosttyTiledPaneHost.grid(
            windowPx: CGSize(width: 1600, height: 850), cellPx: .zero, chromeRows: 1)
        XCTAssertEqual(zeroCell.cols, 2)
        XCTAssertEqual(zeroCell.rows, 1)

        // A window shorter than its own chrome still declares a legal grid.
        let tiny = GhosttyTiledPaneHost.grid(
            windowPx: CGSize(width: 4, height: 10), cellPx: cell, chromeRows: 1)
        XCTAssertGreaterThanOrEqual(tiny.cols, 2)
        XCTAssertGreaterThanOrEqual(tiny.rows, 1)
    }
}
