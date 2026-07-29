import XCTest
import BentoWorkbench
@testable import BentoTmuxPane

/// Snapshot decode → WorkspaceEntry projection, against a literal in the
/// daemon's exact wire shape (acphost/tmuxpane.go `tmuxStructureState` over
/// tmuxcm.StructureSnapshot; statekv's base64 wrapper is the transport's
/// business, so these bytes are the JSON the client actually decodes).
@MainActor
final class TmuxStructureProjectionTests: XCTestCase {
    /// A `bento` session as the mirror publishes it: window 0 holds claude
    /// (active, 80 cols) beside zsh (79 cols, divider column at x=80);
    /// window 1 is a lone tail -f. Pane ids are bare ints on the wire, and
    /// there is no command field — the daemon keeps flapping process
    /// introspection out of change-detected structure.
    static let capturedSnapshot = Data("""
    {"rev":7,"target":"local","session":"bento","structure":{"windows":[
      {"index":0,"name":"work","layout":"d5d2,160x48,0,0{80x48,0,0,1,79x48,81,0,2}",
       "panes":[1,2],
       "details":[
         {"id":1,"title":"✳ claude","width":80,"height":48,"x":0,"y":0,
          "active":true},
         {"id":2,"width":79,"height":48,"x":81,"y":0}]},
      {"index":1,"name":"logs","layout":"c1a2,160x48,0,0,5",
       "panes":[5],
       "details":[
         {"id":5,"title":"tail","width":160,"height":48,"x":0,"y":0,
          "active":true}]}
    ]}}
    """.utf8)

    private func decoded() throws -> TmuxStructureState {
        try XCTUnwrap(TmuxStructureDecoding.decode(Self.capturedSnapshot))
    }

    // MARK: - Decode

    func testDecodesTheDaemonWireShape() throws {
        let state = try decoded()
        XCTAssertEqual(state.rev, 7)
        XCTAssertEqual(state.target, "local")
        XCTAssertEqual(state.session, "bento")
        XCTAssertEqual(state.structure.windows.count, 2)
        XCTAssertEqual(state.structure.windows[0].panes, [1, 2])
        XCTAssertEqual(state.structure.windows[0].details[0].title, "✳ claude")
        XCTAssertTrue(state.structure.windows[0].details[0].active)
        XCTAssertEqual(state.structure.windows[0].details[1].title, "")   // omitempty
        XCTAssertEqual(state.structure.windows[1].details[0].id, 5)
    }

    func testRejectsNonSnapshotPayloads() {
        XCTAssertNil(TmuxStructureDecoding.decode(Data("not json".utf8)))
        XCTAssertNil(TmuxStructureDecoding.decode(Data("{}".utf8)))
    }

    func testStatekvKeyMatchesTheDaemon() {
        XCTAssertEqual(TmuxStructureDecoding.statekvKey(target: "local"),
                       "tmux/local/structure")
    }

    // MARK: - Projection

    func testProjectsSessionAndAllWindowsPanes() throws {
        let entry = try XCTUnwrap(decoded().workspaceEntry(entryID: 3))
        XCTAssertEqual(entry.id, 3)
        XCTAssertEqual(entry.name, "bento")
        // Window-then-pane order — the Focus list.
        XCTAssertEqual(entry.panes.map(\.id), [1, 2, 5])
        XCTAssertTrue(entry.panes.allSatisfy { $0.kind == .tmux })
        // The virtual instance id IS the attach handle.
        XCTAssertEqual(entry.panes.map(\.instanceID),
                       ["tmux:local:%1", "tmux:local:%2", "tmux:local:%5"])
        XCTAssertEqual(entry.panes[0].title, "✳ claude")
        XCTAssertNil(entry.panes[1].title)
        // No command on the wire (kept out of the mirror by design) —
        // nothing may be invented for it.
        XCTAssertTrue(entry.panes.allSatisfy { $0.startCommand == nil })
        XCTAssertTrue(entry.panes.allSatisfy { $0.acpSessionID == nil })
    }

    func testProjectsParallelWindowGeometry() throws {
        let entry = try XCTUnwrap(decoded().workspaceEntry(entryID: 0))
        XCTAssertEqual(entry.cols, 160)
        XCTAssertEqual(entry.rows, 48)
        XCTAssertEqual(entry.activePane, 1)
        XCTAssertNil(entry.zoomedPane)

        // The layout is the lowest-indexed window's tmux geometry as a
        // fraction tree: claude left of zsh, edges shared, full coverage
        // (the one-cell divider is absorbed by renormalization).
        XCTAssertEqual(LayoutTree.leafOrder(of: entry.layout), [1, 2])
        let frames = LayoutTree.frames(of: entry.layout)
        let claude = try XCTUnwrap(frames[1])
        let zsh = try XCTUnwrap(frames[2])
        XCTAssertEqual(claude.x, 0)
        XCTAssertEqual(zsh.x, claude.w)                       // shared edge
        XCTAssertEqual(claude.w + zsh.w, LayoutTree.legacyCols)
        XCTAssertEqual(claude.h, LayoutTree.legacyRows)
    }

    func testProjectsNestedSplits() throws {
        // claude | (zsh over tail): a vertical cut at x=80, then a
        // horizontal cut in the right column (divider row at y=24).
        let state = TmuxStructureState(
            rev: 1, target: "local", session: "grid",
            structure: TmuxStructureSnapshot(windows: [
                TmuxSnapshotWindow(index: 0, name: "w", panes: [1, 2, 3], details: [
                    TmuxSnapshotPane(id: 1, width: 80, height: 48, x: 0, y: 0, active: true),
                    TmuxSnapshotPane(id: 2, width: 79, height: 24, x: 81, y: 0),
                    TmuxSnapshotPane(id: 3, width: 79, height: 23, x: 81, y: 25),
                ]),
            ]))
        let entry = try XCTUnwrap(state.workspaceEntry(entryID: 0))
        XCTAssertEqual(LayoutTree.leafOrder(of: entry.layout), [1, 2, 3])
        let frames = LayoutTree.frames(of: entry.layout)
        let left = try XCTUnwrap(frames[1])
        let topRight = try XCTUnwrap(frames[2])
        let bottomRight = try XCTUnwrap(frames[3])
        XCTAssertEqual(left.h, LayoutTree.legacyRows)
        XCTAssertEqual(topRight.x, left.w)
        XCTAssertEqual(bottomRight.y, topRight.h)
        XCTAssertEqual(topRight.h + bottomRight.h, LayoutTree.legacyRows)
    }

    func testZoomedWindowMarksTheActivePane() throws {
        var state = try decoded()
        // window_zoomed_flag is per-window: both panes report it.
        state.structure.windows[0].details[0].zoomed = true
        state.structure.windows[0].details[1].zoomed = true
        let entry = try XCTUnwrap(state.workspaceEntry(entryID: 0))
        XCTAssertEqual(entry.zoomedPane, 1)
    }

    func testDetailFreeSnapshotFallsBackToTiledGrid() throws {
        // An old Swift-era stash: pane ids only, no geometry.
        let state = TmuxStructureState(
            rev: 1, target: "local", session: "stash",
            structure: TmuxStructureSnapshot(windows: [
                TmuxSnapshotWindow(index: 0, name: "w", panes: [7, 9]),
            ]))
        let entry = try XCTUnwrap(state.workspaceEntry(entryID: 0))
        XCTAssertEqual(Set(LayoutTree.leafOrder(of: entry.layout)), [7, 9])
    }

    func testEmptySnapshotProjectsNothing() {
        let state = TmuxStructureState(
            rev: 1, target: "local", session: "empty",
            structure: TmuxStructureSnapshot(windows: []))
        XCTAssertNil(state.workspaceEntry(entryID: 0))
    }
}
