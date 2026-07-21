import XCTest
@testable import BentoCore

/// The window-era (schema v1) persisted blob must flatten into the pane-only
/// v2 shape: every window's panes join the session, the layout rebuilds as a
/// tiled grid, the active window's active pane survives as the session's.
@MainActor
final class WorkspaceStoreMigrationTests: XCTestCase {
    private let legacyBlob = """
    {
      "sessions": [
        {
          "id": 1, "name": "work",
          "windows": [
            {"id": 1, "name": "one", "layout": "b25f,160x48,0,0{79x48,0,0,1,80x48,80,0,2}", "activePane": 2, "zoomed": false},
            {"id": 2, "name": "two", "layout": "aaaa,160x48,0,0,3", "activePane": 3, "zoomed": true}
          ],
          "panes": [
            {"id": 1, "windowID": 1, "presetID": "opencode", "cwd": "/tmp/a"},
            {"id": 2, "windowID": 1, "presetID": "claude-code", "cwd": "/tmp/b"},
            {"id": 3, "windowID": 2, "presetID": "codex", "cwd": "/tmp/c", "title": "named"}
          ],
          "activeWindow": 1,
          "options": {"@bento_mode": "list"},
          "cols": 160, "rows": 48
        }
      ],
      "nextPane": 4, "nextWindow": 3, "nextSession": 2
    }
    """

    func testLegacyBlobFlattensToPaneOnlySession() throws {
        let decoded = AgentWorkspaceStore.decodeState(Data(legacyBlob.utf8))
        let result = try XCTUnwrap(decoded)
        XCTAssertTrue(result.migrated)
        XCTAssertEqual(result.state.sessions.count, 1)
        let sess = result.state.sessions[0]
        XCTAssertEqual(sess.name, "work")
        XCTAssertEqual(sess.panes.map(\.id), [1, 2, 3], "window order, pane order within")
        XCTAssertEqual(Set(LayoutTree.leafOrder(of: sess.layout)), [1, 2, 3])
        XCTAssertEqual(sess.activePane, 2, "active window's active pane survives")
        XCTAssertNil(sess.zoomedPane)
        XCTAssertEqual(sess.panes[2].title, "named")
        XCTAssertTrue(sess.panes.allSatisfy { $0.kind == .acp })
        XCTAssertEqual(result.state.nextPane, 4)
        XCTAssertEqual(result.state.nextSession, 2)
    }

    func testV2BlobRoundTripsWithoutMigration() throws {
        var state = AgentWorkspaceStore.State()
        state.sessions = [AgentWorkspaceStore.SessionEntry(
            id: 1, name: "s",
            panes: [.init(id: 1, presetID: "opencode", customPreset: nil, cwd: "/tmp",
                          title: nil, instanceID: "inst-1", acpSessionID: "acp-1",
                          startCommand: nil)],
            layout: LayoutTree.single(pane: 1, w: 160, h: 48),
            activePane: 1, cols: 160, rows: 48)]
        state.nextPane = 2
        state.nextSession = 2
        let data = try JSONEncoder().encode(state)
        let decoded = AgentWorkspaceStore.decodeState(data)
        let result = try XCTUnwrap(decoded)
        XCTAssertFalse(result.migrated)
        XCTAssertEqual(result.state.sessions[0].panes[0].instanceID, "inst-1")
        XCTAssertEqual(result.state.sessions[0].panes[0].acpSessionID, "acp-1")
        XCTAssertEqual(LayoutTree.leafOrder(of: result.state.sessions[0].layout), [1])
    }

    func testGarbageBlobDecodesToNil() {
        XCTAssertNil(AgentWorkspaceStore.decodeState(Data("not json".utf8)))
        XCTAssertNil(AgentWorkspaceStore.decodeState(Data("{\"x\":1}".utf8)))
    }
}
