import XCTest
@testable import BentoTerminalCore

/// The fractional layout model: unit-canvas invariants, the legacy cell-tree
/// canonicalization, and the two compatibility shims (160×48 Int projection,
/// Int-cell resize amounts).
final class LayoutTreeFractionTests: XCTestCase {

    private func fractions(_ n: LayoutTree.Node) -> [Int: (w: Double, h: Double, x: Double, y: Double)] {
        LayoutTree.fractions(of: n)
    }

    func testSingleFillsUnitCanvas() {
        let f = fractions(LayoutTree.single(pane: 1))[1]!
        XCTAssertEqual(f.w, 1, accuracy: 1e-9)
        XCTAssertEqual(f.h, 1, accuracy: 1e-9)
        XCTAssertEqual(f.x, 0, accuracy: 1e-9)
    }

    func testSplittingHalvesExactly() {
        let split = LayoutTree.splitting(pane: 1, adding: 2, horizontal: true,
                                         in: LayoutTree.single(pane: 1))!
        let f = fractions(split)
        // No divider column: both halves are exactly 0.5, edges shared.
        XCTAssertEqual(f[1]!.w, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f[2]!.w, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f[2]!.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f[1]!.w + f[2]!.w, 1, accuracy: 1e-9)
    }

    func testLegacyCellTreeCanonicalizes() throws {
        // A tmux-era absolute-cell tree: 160×48 canvas, one divider column
        // between a 79-cell and an 80-cell pane.
        let json = """
        {"type":"hsplit","w":160,"h":48,"x":0,"y":0,"children":[
          {"type":"leaf","id":1,"w":79,"h":48,"x":0,"y":0},
          {"type":"leaf","id":2,"w":80,"h":48,"x":80,"y":0}]}
        """
        let node = try JSONDecoder().decode(LayoutTree.Node.self, from: Data(json.utf8))
        let f = fractions(node)
        // Proportions preserved (≈ half each), divider gap absorbed.
        XCTAssertEqual(f[1]!.w, 0.5, accuracy: 0.01)
        XCTAssertEqual(f[2]!.w, 0.5, accuracy: 0.01)
        XCTAssertEqual(f[1]!.w + f[2]!.w, 1, accuracy: 1e-9)
        XCTAssertEqual(f[2]!.x, f[1]!.w, accuracy: 1e-9)
        XCTAssertEqual(Set(LayoutTree.leafOrder(of: node)), [1, 2])
    }

    func testFramesProjectionTilesExactly() {
        var tree = LayoutTree.single(pane: 1)
        tree = LayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: tree)!
        tree = LayoutTree.splitting(pane: 2, adding: 3, horizontal: false, in: tree)!
        let frames = LayoutTree.frames(of: tree)
        // Left pane spans the full height; the right column stacks 2 and 3.
        let a = frames[1]!, b = frames[2]!, c = frames[3]!
        XCTAssertEqual(a.x, 0)
        XCTAssertEqual(a.w + b.w, LayoutTree.legacyCols)   // edges shared, no divider loss
        XCTAssertEqual(b.x, a.w)
        XCTAssertEqual(c.x, b.x)
        XCTAssertEqual(b.h + c.h, LayoutTree.legacyRows)
        XCTAssertEqual(c.y, b.h)
        XCTAssertEqual(a.h, LayoutTree.legacyRows)
    }

    func testResizingShimMovesByLegacyCells() {
        let split = LayoutTree.splitting(pane: 1, adding: 2, horizontal: true,
                                         in: LayoutTree.single(pane: 1))!
        // Grow pane 1 rightward by 16 legacy cells = 16/160 = 0.1 of the canvas.
        let resized = LayoutTree.resizing(pane: 1, direction: "R", amount: 16, in: split)
        let f = fractions(resized)
        XCTAssertEqual(f[1]!.w, 0.6, accuracy: 1e-9)
        XCTAssertEqual(f[2]!.w, 0.4, accuracy: 1e-9)
    }

    func testResizingClampsAtMinShare() {
        let split = LayoutTree.splitting(pane: 1, adding: 2, horizontal: true,
                                         in: LayoutTree.single(pane: 1))!
        // Try to grow far past the sibling: partner is clamped at minShare.
        let resized = LayoutTree.resizing(pane: 1, direction: "R", amount: 1000, in: split)
        let f = fractions(resized)
        XCTAssertEqual(f[2]!.w, LayoutTree.minShare, accuracy: 1e-9)
        XCTAssertEqual(f[1]!.w, 1 - LayoutTree.minShare, accuracy: 1e-9)
    }

    func testRemovingRedistributesProportionally() {
        var tree = LayoutTree.single(pane: 1)
        tree = LayoutTree.splitting(pane: 1, adding: 2, horizontal: true, in: tree)!
        tree = LayoutTree.splitting(pane: 2, adding: 3, horizontal: true, in: tree)!
        let pruned = LayoutTree.removing(pane: 2, from: tree)!
        let f = fractions(pruned)
        XCTAssertNil(f[2])
        XCTAssertEqual(f[1]!.w + f[3]!.w, 1, accuracy: 1e-9)
        // 1 had 0.5, 3 had 0.25 → after redistribute they keep the 2:1 ratio.
        XCTAssertEqual(f[1]!.w / f[3]!.w, 2, accuracy: 0.01)
    }

    func testCodableRoundTripsFractions() throws {
        var tree = LayoutTree.single(pane: 1)
        tree = LayoutTree.splitting(pane: 1, adding: 2, horizontal: false, in: tree)!
        tree = LayoutTree.resizing(pane: 1, direction: "D", amount: 6, in: tree)
        let data = try JSONEncoder().encode(tree)
        let back = try JSONDecoder().decode(LayoutTree.Node.self, from: data)
        XCTAssertEqual(back, tree)
    }

    func testTiledPresetEvensOut() {
        let tree = LayoutTree.tiledPreset(panes: [1, 2, 3, 4])!
        let f = fractions(tree)
        for id in 1...4 {
            XCTAssertEqual(f[id]!.w, 0.5, accuracy: 1e-9)
            XCTAssertEqual(f[id]!.h, 0.5, accuracy: 1e-9)
        }
    }
}
