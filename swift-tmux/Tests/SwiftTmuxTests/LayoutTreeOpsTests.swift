import XCTest
@testable import SwiftTmux

/// The ACP-side layout verbs must reproduce tmux's split/swap/resize/dock
/// geometry. Trees are checked via leafOrder + per-leaf frames.
final class LayoutTreeOpsTests: XCTestCase {
    typealias Node = TmuxLayoutTree.Node

    private func frames(_ node: Node) -> [Int: (w: Int, h: Int, x: Int, y: Int)] {
        var out: [Int: (Int, Int, Int, Int)] = [:]
        func walk(_ n: Node) {
            switch n {
            case .leaf(let id, let w, let h, let x, let y): out[id] = (w, h, x, y)
            case .hsplit(_, _, _, _, let c), .vsplit(_, _, _, _, let c): c.forEach(walk)
            }
        }
        walk(node)
        return out
    }

    /// Invariants tmux maintains: children fill the container minus one-cell
    /// dividers, and offsets chain contiguously.
    private func assertConsistent(_ node: Node, file: StaticString = #filePath, line: UInt = #line) {
        func walk(_ n: Node) {
            switch n {
            case .leaf: break
            case .hsplit(let w, let h, _, _, let children):
                XCTAssertEqual(children.map(\.width).reduce(0, +) + children.count - 1, w,
                               "hsplit children + dividers ≠ width", file: file, line: line)
                children.forEach { XCTAssertEqual($0.height, h, file: file, line: line); walk($0) }
            case .vsplit(let w, let h, _, _, let children):
                XCTAssertEqual(children.map(\.height).reduce(0, +) + children.count - 1, h,
                               "vsplit children + dividers ≠ height", file: file, line: line)
                children.forEach { XCTAssertEqual($0.width, w, file: file, line: line); walk($0) }
            }
        }
        walk(node)
    }

    func testSingleAndHorizontalSplit() {
        let base = TmuxLayoutTree.single(pane: 1, w: 160, h: 48)
        guard let split = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base) else {
            return XCTFail("split failed")
        }
        XCTAssertEqual(TmuxLayoutTree.leafOrder(of: split), [1, 2])
        let f = frames(split)
        // 160 wide → 79 + divider + 80 (halves, second takes the rounding).
        XCTAssertEqual(f[1]!.w + f[2]!.w + 1, 160)
        XCTAssertEqual(f[1]!.x, 0)
        XCTAssertEqual(f[2]!.x, f[1]!.w + 1)
        XCTAssertEqual(f[1]!.h, 48)
        assertConsistent(split)
    }

    func testVerticalSplitThenSameAxisFlattens() {
        let base = TmuxLayoutTree.single(pane: 1, w: 100, h: 60)
        let one = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: false, in: base)!
        let two = TmuxLayoutTree.splitting(pane: 2, adding: 3, horizontal: false, in: one)!
        // Same-axis nesting flattens: one vsplit with three children.
        guard case .vsplit(_, _, _, _, let children) = two else { return XCTFail("expected vsplit") }
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(TmuxLayoutTree.leafOrder(of: two), [1, 2, 3])
        assertConsistent(two)
    }

    func testSplitBeforePutsNewPaneFirst() {
        let base = TmuxLayoutTree.single(pane: 1, w: 100, h: 60)
        let split = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, newFirst: true, in: base)!
        XCTAssertEqual(TmuxLayoutTree.leafOrder(of: split), [2, 1])
    }

    func testSplitRejectsBadIDs() {
        let base = TmuxLayoutTree.single(pane: 1, w: 100, h: 60)
        XCTAssertNil(TmuxLayoutTree.splitting(pane: 9, adding: 2, horizontal: true, in: base))
        XCTAssertNil(TmuxLayoutTree.splitting(pane: 1, adding: 1, horizontal: true, in: base))
    }

    func testCrossAxisSplitNests() {
        let base = TmuxLayoutTree.single(pane: 1, w: 100, h: 60)
        let one = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        let two = TmuxLayoutTree.splitting(pane: 2, adding: 3, horizontal: false, in: one)!
        guard case .hsplit(_, _, _, _, let children) = two else { return XCTFail("expected hsplit root") }
        XCTAssertEqual(children.count, 2)
        guard case .vsplit = children[1] else { return XCTFail("expected nested vsplit") }
        XCTAssertEqual(TmuxLayoutTree.leafOrder(of: two), [1, 2, 3])
        assertConsistent(two)
    }

    func testSwapExchangesIDsNotGeometry() {
        let base = TmuxLayoutTree.single(pane: 1, w: 100, h: 60)
        let split = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        let before = frames(split)
        let swapped = TmuxLayoutTree.swapping(1, 2, in: split)
        let after = frames(swapped)
        XCTAssertEqual(after[1]!.x, before[2]!.x)
        XCTAssertEqual(after[2]!.x, before[1]!.x)
        XCTAssertEqual(TmuxLayoutTree.leafOrder(of: swapped), [2, 1])
    }

    func testNeighborWraps() {
        let base = TmuxLayoutTree.single(pane: 1, w: 100, h: 60)
        let one = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        let two = TmuxLayoutTree.splitting(pane: 2, adding: 3, horizontal: true, in: one)!
        XCTAssertEqual(TmuxLayoutTree.neighbor(of: 1, previous: false, in: two), 2)
        XCTAssertEqual(TmuxLayoutTree.neighbor(of: 1, previous: true, in: two), 3)   // wrap
        XCTAssertEqual(TmuxLayoutTree.neighbor(of: 3, previous: false, in: two), 1)  // wrap
    }

    func testResizeGrowsRightAndClamps() {
        let base = TmuxLayoutTree.single(pane: 1, w: 101, h: 60)
        let split = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        let f0 = frames(split)
        let grown = TmuxLayoutTree.resizing(pane: 1, direction: "R", amount: 10, in: split)
        let f1 = frames(grown)
        XCTAssertEqual(f1[1]!.w, f0[1]!.w + 10)
        XCTAssertEqual(f1[2]!.w, f0[2]!.w - 10)
        assertConsistent(grown)

        // Clamp: cannot shrink the neighbor below 1 cell.
        let maxed = TmuxLayoutTree.resizing(pane: 1, direction: "R", amount: 1000, in: split)
        let f2 = frames(maxed)
        XCTAssertEqual(f2[2]!.w, 1)
        assertConsistent(maxed)
    }

    func testResizeLastChildFallsBackToOtherBorder() {
        let base = TmuxLayoutTree.single(pane: 1, w: 101, h: 60)
        let split = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        // Pane 2 is the last child: "R" (grow) takes from the PREVIOUS sibling.
        let f0 = frames(split)
        let grown = TmuxLayoutTree.resizing(pane: 2, direction: "R", amount: 5, in: split)
        let f1 = frames(grown)
        XCTAssertEqual(f1[2]!.w, f0[2]!.w + 5)
        XCTAssertEqual(f1[1]!.w, f0[1]!.w - 5)
        assertConsistent(grown)
    }

    func testResizeVerticalDirectionUnaffectedByHorizontalOnly() {
        // A pure hsplit has no vertical boundary — U/D must be a no-op.
        let base = TmuxLayoutTree.single(pane: 1, w: 100, h: 60)
        let split = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        let same = TmuxLayoutTree.resizing(pane: 1, direction: "D", amount: 5, in: split)
        XCTAssertEqual(frames(same)[1]!.h, frames(split)[1]!.h)
    }

    func testDockMovesSourceBesideTarget() {
        // Three side-by-side panes; dock 1 below 3.
        let base = TmuxLayoutTree.single(pane: 1, w: 150, h: 60)
        let one = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        let two = TmuxLayoutTree.splitting(pane: 2, adding: 3, horizontal: true, in: one)!
        guard let docked = TmuxLayoutTree.docking(pane: 1, at: 3, horizontal: false, before: false, in: two) else {
            return XCTFail("dock failed")
        }
        XCTAssertEqual(Set(TmuxLayoutTree.leafOrder(of: docked)), [1, 2, 3])
        let f = frames(docked)
        // 1 ends up directly below 3: same x span, greater y.
        XCTAssertEqual(f[1]!.x, f[3]!.x)
        XCTAssertGreaterThan(f[1]!.y, f[3]!.y)
        assertConsistent(docked)
    }

    func testDockBeforePutsSourceAboveTarget() {
        let base = TmuxLayoutTree.single(pane: 1, w: 150, h: 60)
        let one = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        guard let docked = TmuxLayoutTree.docking(pane: 1, at: 2, horizontal: false, before: true, in: one) else {
            return XCTFail("dock failed")
        }
        let f = frames(docked)
        XCTAssertLessThan(f[1]!.y, f[2]!.y)
        XCTAssertEqual(f[1]!.x, f[2]!.x)
    }

    func testDockRejectsOnlyPaneAndSelf() {
        let base = TmuxLayoutTree.single(pane: 1, w: 100, h: 60)
        XCTAssertNil(TmuxLayoutTree.docking(pane: 1, at: 1, horizontal: true, before: false, in: base))
        let split = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        // Removing 1 from a two-pane tree leaves a single leaf — still valid.
        XCTAssertNotNil(TmuxLayoutTree.docking(pane: 1, at: 2, horizontal: true, before: false, in: split))
    }

    func testCanvasResizeKeepsProportions() {
        let base = TmuxLayoutTree.single(pane: 1, w: 100, h: 60)
        let split = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: base)!
        let big = TmuxLayoutTree.resized(split, w: 201, h: 100)
        let f = frames(big)
        XCTAssertEqual(f[1]!.w + f[2]!.w + 1, 201)
        XCTAssertEqual(f[1]!.h, 100)
        assertConsistent(big)
    }

    func testRoundTripThroughSerialization() {
        let base = TmuxLayoutTree.single(pane: 0, w: 160, h: 48)
        let a = TmuxLayoutTree.splitting(pane: 0, adding: 1, horizontal: true, in: base)!
        let b = TmuxLayoutTree.splitting(pane: 1, adding: 2, horizontal: false, in: a)!
        let s = TmuxLayoutTree.serialize(b)
        let parsed = TmuxLayoutTree.parse(s)
        XCTAssertEqual(parsed, b, "serialize→parse must round-trip layout verbs' output")
    }
}
