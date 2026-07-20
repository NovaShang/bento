import XCTest
import SwiftTmux
@testable import BentoTerminalCore

/// The ACP bridge must speak the exact dialect TerminalViewModel already
/// parses: list responses through TmuxParsers, tmux verb semantics through
/// the workspace store. No launcher is injected — agents never spawn, the
/// structure layer is exercised pure.
@MainActor
final class AcpBridgeTests: XCTestCase {
    private var store: AgentWorkspaceStore!
    private var bridge: AcpTmuxBridge!

    override func setUp() async throws {
        // Fresh, unpersisted store per test (shared-instance persistence is
        // keyed off UserDefaults; tests must not touch the real workspace).
        UserDefaults.standard.removeObject(forKey: "acp_workspace_v1")
        store = AgentWorkspaceStore()
        bridge = AcpTmuxBridge(store: store)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "acp_workspace_v1")
    }

    private func attach(_ name: String = "work") async {
        _ = bridge.launchCommand(sessionName: name, groupWith: nil)
        _ = await bridge.awaitControlMode(timeout: .seconds(1))
    }

    private func panes() async -> [Pane] {
        let resp = await bridge.send(.listPanes(sessionWide: true))
        XCTAssertFalse(resp.isError)
        return TmuxParsers.parsePaneList(resp.output)
    }

    private func windows() async -> [TmuxWindow] {
        let resp = await bridge.send(.listWindows())
        XCTAssertFalse(resp.isError)
        return TmuxParsers.parseWindowList(resp.output)
    }

    // MARK: - Attach & serialization round-trip

    func testAttachCreatesSessionWithOnePane() async {
        await attach()
        let panes = await panes()
        XCTAssertEqual(panes.count, 1)
        XCTAssertTrue(panes[0].isActive)
        XCTAssertTrue(panes[0].inActiveWindow)
        XCTAssertNotNil(panes[0].windowID)
        let windows = await windows()
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows[0].isActive)
        // The layout survives the list-windows round-trip and parses.
        XCTAssertNotNil(windows[0].layout.flatMap { TmuxLayoutTree.parse($0) })
    }

    func testListSessionsFormat() async {
        await attach("alpha")
        let resp = await bridge.send(.listSessions)
        XCTAssertFalse(resp.isError)
        XCTAssertTrue(resp.output.split(separator: "\n").allSatisfy { $0.hasPrefix("$") })
        XCTAssertTrue(resp.output.contains(":alpha"))
    }

    func testDuplicateNewSessionErrors() async {
        await attach("alpha")
        let resp = await bridge.send(.newSession(name: "alpha"))
        XCTAssertTrue(resp.isError)
        XCTAssertTrue(resp.output.contains("duplicate session"))
    }

    // MARK: - Split / kill / zoom

    func testSplitProducesTwoPanesAndFocusesNew() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        let after = await panes()
        XCTAssertEqual(after.count, 2)
        let newPane = after.first { $0.id != first.id }!
        XCTAssertTrue(newPane.isActive, "split lands focused, like tmux")
        // Side-by-side: same y, disjoint x.
        let a = after[0], b = after[1]
        XCTAssertEqual(a.y, b.y)
        XCTAssertNotEqual(a.x, b.x)
    }

    func testKillPaneCollapsesAndLastPaneKillsSession() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: false))
        var all = await panes()
        XCTAssertEqual(all.count, 2)
        let victim = all.first { $0.id != first.id }!
        _ = await bridge.send(.killPane(id: victim.id))
        all = await panes()
        XCTAssertEqual(all.count, 1)
        // Survivor reclaims the full canvas.
        XCTAssertEqual(all[0].height, AgentWorkspaceStore.defaultRows)

        _ = await bridge.send(.killPane(id: all[0].id))
        let resp = await bridge.send(.listPanes(sessionWide: true))
        XCTAssertTrue(resp.isError, "last pane kills window kills session")
    }

    func testZoomFlagRoundTrips() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        _ = await bridge.send(.zoomPane(id: first.id))
        let zoomed = await panes()
        // The view model reads zoom off the ACTIVE pane's flag; zooming also
        // focuses the pane.
        XCTAssertEqual(zoomed.first { $0.isActive }?.id, first.id)
        XCTAssertTrue(zoomed.first { $0.isActive }!.isZoomed)
        _ = await bridge.send(.zoomPane(id: first.id))
        let unzoomed = await panes()
        XCTAssertTrue(unzoomed.allSatisfy { !$0.isZoomed })
    }

    func testSelectingOtherPaneUnzooms() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        let second = (await panes()).first { $0.id != first.id }!
        _ = await bridge.send(.zoomPane(id: first.id))
        _ = await bridge.send(.selectPane(id: second.id))
        let after = await panes()
        XCTAssertTrue(after.allSatisfy { !$0.isZoomed }, "selecting a hidden pane unzooms")
        XCTAssertEqual(after.first { $0.isActive }?.id, second.id)
    }

    // MARK: - Windows

    func testNewWindowAddsPaneToTheSession() async {
        // With windows gone, the "New Window" verb lands a fresh pane in the
        // session (largest-cell insertion), focused.
        await attach()
        _ = await bridge.send(.newWindow())
        let wins = await windows()
        XCTAssertEqual(wins.count, 1, "one fake window per session")
        let all = await panes()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter(\.isActive).count, 1)
        XCTAssertTrue(all.allSatisfy(\.inActiveWindow))
    }

    func testWindowVerbsAnswerHarmlessly() async {
        // Windows are gone; the transitional shim answers the dead verbs
        // without error and without touching structure.
        await attach()
        _ = await bridge.send(.splitWindow(target: (await panes())[0].id, horizontal: true))
        let before = await panes()
        let wins = await windows()
        let selectResp = await bridge.send(.selectWindow(id: wins[0].id))
        XCTAssertFalse(selectResp.isError)
        let renameResp = await bridge.send(.renameWindow(id: wins[0].id, name: "x"))
        XCTAssertFalse(renameResp.isError)
        let after = await panes()
        XCTAssertEqual(after.map(\.id), before.map(\.id))
    }

    // MARK: - Structure transforms (two-mode machinery is dead)

    func testBreakPaneErrors() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        let second = (await panes()).first { $0.id != first.id }!
        let resp = await bridge.send(.breakPane(source: second.id, name: "broken"))
        XCTAssertTrue(resp.isError, "windows are gone; break-pane is dead")
        let after = await panes()
        XCTAssertEqual(after.count, 2, "structure untouched")
    }

    func testJoinPaneMergesWindows() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.newWindow())
        let other = (await panes()).first { $0.id != first.id }!
        let resp = await bridge.send(.joinPane(source: other.id, target: first.id))
        XCTAssertFalse(resp.isError)
        let wins = await windows()
        XCTAssertEqual(wins.count, 1, "emptied window dies")
        let all = await panes()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.compactMap(\.windowID)).count, 1)
    }

    func testJoinPaneSameSessionDocksBelowTarget() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        let second = (await panes()).first { $0.id != first.id }!
        let resp = await bridge.send(.joinPane(source: second.id, target: first.id))
        XCTAssertFalse(resp.isError, "same-session join = edge dock below the target")
        let all = await panes()
        XCTAssertEqual(all.count, 2)
        let target = all.first { $0.id == first.id }!
        let source = all.first { $0.id == second.id }!
        XCTAssertGreaterThan(source.y, target.y, "source lands below the target")
    }

    func testSelectLayoutTiledEvensOut() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        let win = (await windows())[0]
        _ = await bridge.send(.selectLayout(window: win.id, layout: "tiled"))
        let all = await panes()
        XCTAssertEqual(all.count, 3)
        // tmux tiled for 3 panes: 2x2 grid, rows of 2 + 1.
        let ys = Set(all.map(\.y))
        XCTAssertEqual(ys.count, 2, "two rows")
    }

    // MARK: - Cross-session moves

    func testJoinPaneToSessionLandsInCurrentWindow() async {
        await attach("source")
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        let mover = (await panes()).first { $0.id != first.id }!
        _ = await bridge.send(.newSession(name: "target"))
        let resp = await bridge.send(.joinPaneToSession(source: mover.id, session: "target"))
        XCTAssertFalse(resp.isError)
        // Source still lives (had 2 panes).
        let sourcePanes = await panes()
        XCTAssertEqual(sourcePanes.count, 1)
        // Target's current window now holds 2 panes.
        let targetPanes = TmuxParsers.parsePaneList(
            (await bridge.send(.listPanes(target: "target", sessionWide: true))).output)
        XCTAssertEqual(targetPanes.count, 2)
        XCTAssertEqual(Set(targetPanes.compactMap(\.windowID)).count, 1)
    }

    func testMoveWindowErrors() async {
        await attach("source")
        _ = await bridge.send(.newSession(name: "target"))
        let wins = await windows()
        let resp = await bridge.send(.moveWindow(id: wins[0].id, targetSession: "target:"))
        XCTAssertTrue(resp.isError, "windows are gone; move-window is dead")
    }

    func testMovingLastPaneKillsSourceSession() async {
        await attach("source")
        let only = await panes()[0]
        _ = await bridge.send(.newSession(name: "target"))
        _ = await bridge.send(.switchClient(session: "target"))
        let resp = await bridge.send(.joinPaneToSession(source: only.id, session: "target"))
        XCTAssertFalse(resp.isError)
        let sessions = (await bridge.send(.listSessions)).output
        XCTAssertFalse(sessions.contains("source"), "emptied source session dies")
    }

    // MARK: - Options, display-message, misc

    func testSessionOptionsAreInert() async {
        // Session options died with the two-mode machinery: sets are absorbed,
        // reads always answer "unset".
        await attach()
        let setResp = await bridge.send(.setSessionOption(name: "@bento_mode", value: "list"))
        XCTAssertFalse(setResp.isError)
        let resp = await bridge.send(.showSessionOption(name: "@bento_mode"))
        XCTAssertFalse(resp.isError)
        XCTAssertEqual(resp.output, "")
    }

    func testDisplayMessageAnswersCwdAndCommand() async {
        await attach()
        let pane = await panes()[0]
        let cwd = await bridge.send(.displayMessage(format: "#{pane_current_path}", target: pane.id))
        XCTAssertFalse(cwd.isError)
        XCTAssertTrue(cwd.output.hasPrefix("/"))
        let cmd = await bridge.send(.displayMessage(format: "#{pane_current_command}", target: pane.id))
        XCTAssertFalse(cmd.isError)
        XCTAssertFalse(cmd.output.isEmpty)
        let cursor = await bridge.send(.displayMessage(format: "#{cursor_y} #{cursor_x}", target: pane.id))
        XCTAssertTrue(cursor.isError, "no character grid — seeding must give up")
    }

    func testCapturePaneErrors() async {
        await attach()
        let pane = await panes()[0]
        let resp = await bridge.send(.capturePane(id: pane.id, lines: 10))
        XCTAssertTrue(resp.isError)
    }

    func testResizePaneByMovesDivider() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        let before = await panes()
        let w0 = before.first { $0.id == first.id }!.width
        _ = await bridge.send(.resizePaneBy(id: first.id, direction: "R", amount: 8))
        let after = await panes()
        XCTAssertEqual(after.first { $0.id == first.id }!.width, w0 + 8)
    }

    func testRefreshClientResizesCanvas() async {
        await attach()
        _ = await bridge.send(.refreshClient(width: 200, height: 60))
        let pane = await panes()[0]
        XCTAssertEqual(pane.width, 200)
        XCTAssertEqual(pane.height, 60)
    }

    func testSwapPanesTradesPositions() async {
        await attach()
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        let before = await panes()
        let a = before[0], b = before[1]
        _ = await bridge.send(.swapPanes(source: a.id, destination: b.id))
        let after = await panes()
        XCTAssertEqual(after.first { $0.id == a.id }!.x, b.x)
        XCTAssertEqual(after.first { $0.id == b.id }!.x, a.x)
    }

    func testStructureEventsReachNotificationSink() async {
        await attach()
        nonisolated(unsafe) var seenStructure = false
        bridge.onNotification = { note in
            if case .windowClose = note { seenStructure = true }
        }
        let first = await panes()[0]
        _ = await bridge.send(.splitWindow(target: first.id, horizontal: true))
        XCTAssertTrue(seenStructure, "structural mutation must ping the refresh pipeline")
    }

    func testPaneTitleRename() async {
        await attach()
        let pane = await panes()[0]
        _ = await bridge.send(.setPaneTitle(id: pane.id, title: "my agent"))
        let after = await panes()
        XCTAssertEqual(after[0].title, "my agent")
    }
}
