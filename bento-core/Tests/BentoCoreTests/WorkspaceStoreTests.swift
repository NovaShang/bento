import XCTest
@testable import BentoCore

/// Structure semantics of the workspace store, driven through its verbs —
/// the same assertions the tmux-dialect bridge tests made, minus the
/// dialect. No launcher is injected: agents never spawn processes, the
/// structure layer is exercised pure.
@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private static let persistKey = "acp_workspace_test"
    private var store: AgentWorkspaceStore!

    override func setUp() async throws {
        // Fresh, unpersisted store per test (must not touch the real
        // workspace's UserDefaults blob).
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
        store = AgentWorkspaceStore(persistKey: Self.persistKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
    }

    private func attach(_ name: String = "work") -> [Pane] {
        _ = store.ensureSession(name)
        return store.paneList(session: name)
    }

    private func panes(_ name: String = "work") -> [Pane] {
        store.paneList(session: name)
    }

    // MARK: - Attach / sessions

    func testAttachCreatesSessionWithOnePane() {
        let panes = attach()
        XCTAssertEqual(panes.count, 1)
        XCTAssertTrue(panes[0].isActive)
        XCTAssertEqual(panes[0].width, AgentWorkspaceStore.defaultCols)
        XCTAssertEqual(panes[0].height, AgentWorkspaceStore.defaultRows)
    }

    func testSessionList() {
        _ = attach("alpha")
        XCTAssertEqual(store.sessionList.map(\.name), ["alpha"])
    }

    func testDuplicateCreateSessionIsRefused() {
        _ = attach("alpha")
        let firstPane = panes("alpha")[0].id
        store.createSession("alpha")
        XCTAssertEqual(store.sessionList.count, 1)
        XCTAssertEqual(panes("alpha").map(\.id), [firstPane], "structure untouched")
    }

    // MARK: - Split / kill / zoom

    func testSplitProducesTwoPanesAndFocusesNew() {
        let first = attach()[0]
        _ = store.splitPane(session: "work", target: first.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        let after = panes()
        XCTAssertEqual(after.count, 2)
        let newPane = after.first { $0.id != first.id }!
        XCTAssertTrue(newPane.isActive, "split lands focused, like tmux")
        // Side-by-side: same y, disjoint x.
        let a = after[0], b = after[1]
        XCTAssertEqual(a.y, b.y)
        XCTAssertNotEqual(a.x, b.x)
    }

    func testKillPaneCollapsesAndLastPaneKillsSession() {
        let first = attach()[0]
        _ = store.splitPane(session: "work", target: first.id.raw,
                            horizontal: false, cwd: nil, command: nil)
        var all = panes()
        XCTAssertEqual(all.count, 2)
        let victim = all.first { $0.id != first.id }!
        store.killPane(victim.id.raw)
        all = panes()
        XCTAssertEqual(all.count, 1)
        // Survivor reclaims the full canvas.
        XCTAssertEqual(all[0].height, AgentWorkspaceStore.defaultRows)

        store.killPane(all[0].id.raw)
        XCTAssertNil(store.session("work"), "last pane kills the session")
    }

    func testZoomRoundTripsAndFocuses() {
        let first = attach()[0]
        _ = store.splitPane(session: "work", target: first.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        store.toggleZoom(first.id.raw)
        let zoomed = panes()
        XCTAssertEqual(zoomed.first { $0.isActive }?.id, first.id, "zoom focuses the pane")
        XCTAssertTrue(zoomed.first { $0.isActive }!.isZoomed)
        store.toggleZoom(first.id.raw)
        XCTAssertTrue(panes().allSatisfy { !$0.isZoomed })
    }

    func testSelectingOtherPaneUnzooms() {
        let first = attach()[0]
        _ = store.splitPane(session: "work", target: first.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        let second = panes().first { $0.id != first.id }!
        store.toggleZoom(first.id.raw)
        store.selectPane(second.id.raw)
        let after = panes()
        XCTAssertTrue(after.allSatisfy { !$0.isZoomed }, "selecting a hidden pane unzooms")
        XCTAssertEqual(after.first { $0.isActive }?.id, second.id)
    }

    // MARK: - New pane (largest-cell insertion)

    func testNewPaneJoinsTheSessionFocused() {
        _ = attach()
        _ = store.newPane(session: "work", cwd: nil, command: nil)
        let all = panes()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter(\.isActive).count, 1)
    }

    // MARK: - Dock (edge drop) & swap

    func testDockLandsBelowTarget() {
        let first = attach()[0]
        _ = store.splitPane(session: "work", target: first.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        let second = panes().first { $0.id != first.id }!
        store.dockPane(second.id.raw, at: first.id.raw, horizontal: false, before: false)
        let all = panes()
        XCTAssertEqual(all.count, 2)
        let target = all.first { $0.id == first.id }!
        let source = all.first { $0.id == second.id }!
        XCTAssertGreaterThan(source.y, target.y, "source lands below the target")
    }

    func testSwapPanesTradesPositions() {
        let first = attach()[0]
        _ = store.splitPane(session: "work", target: first.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        let before = panes()
        let a = before[0], b = before[1]
        store.swapPanes(a.id.raw, b.id.raw)
        let after = panes()
        XCTAssertEqual(after.first { $0.id == a.id }!.x, b.x)
        XCTAssertEqual(after.first { $0.id == b.id }!.x, a.x)
    }

    // MARK: - Cross-session moves

    func testMovePaneLandsInTargetSession() {
        let first = attach("source")[0]
        _ = store.splitPane(session: "source", target: first.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        let mover = panes("source").first { $0.id != first.id }!
        store.createSession("target")
        XCTAssertTrue(store.movePane(mover.id.raw, toSession: "target"))
        XCTAssertEqual(panes("source").count, 1, "source keeps its other pane")
        XCTAssertEqual(panes("target").count, 2, "target holds placeholder + moved pane")
    }

    func testMovingLastPaneKillsSourceSession() {
        let only = attach("source")[0]
        store.createSession("target")
        XCTAssertTrue(store.movePane(only.id.raw, toSession: "target"))
        XCTAssertNil(store.session("source"), "emptied source session dies")
        XCTAssertTrue(panes("target").contains { $0.id == only.id })
    }

    // MARK: - Tiled preset / resize

    func testApplyTiledEvensOut() {
        let first = attach()[0]
        _ = store.splitPane(session: "work", target: first.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        _ = store.splitPane(session: "work", target: first.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        store.applyTiled(session: "work")
        let all = panes()
        XCTAssertEqual(all.count, 3)
        // Tiled for 3 panes: 2x2 grid, rows of 2 + 1.
        XCTAssertEqual(Set(all.map(\.y)).count, 2, "two rows")
    }

    func testResizePaneMovesDivider() {
        let first = attach()[0]
        _ = store.splitPane(session: "work", target: first.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        let w0 = panes().first { $0.id == first.id }!.width
        store.resizePane(first.id.raw, direction: "R", amount: 8)
        XCTAssertEqual(panes().first { $0.id == first.id }!.width, w0 + 8)
    }

    func testPaneGeometryProjectsOntoLegacyGrid() {
        // The layout is fractional: pane geometry always projects onto the
        // fixed legacy 160×48 grid.
        _ = attach()
        let pane = panes()[0]
        XCTAssertEqual(pane.width, LayoutTree.legacyCols)
        XCTAssertEqual(pane.height, LayoutTree.legacyRows)
    }

    // MARK: - Rename, accessors, events

    func testPaneTitleRename() {
        let pane = attach()[0]
        store.renamePane(pane.id.raw, to: "my agent")
        XCTAssertEqual(panes()[0].title, "my agent")
    }

    func testDirectAccessorsAnswerCwdAndCommand() {
        let pane = attach()[0]
        XCTAssertEqual(store.paneCwd(pane.id.raw)?.hasPrefix("/"), true)
        XCTAssertEqual(store.paneCurrentCommand(pane.id.raw)?.isEmpty, false)
        XCTAssertNil(store.paneStartCommand(pane.id.raw), "default-agent pane has no start command")
    }

    func testStructureEventsReachListeners() {
        let pane = attach()[0]
        var seenStructure = false
        let token = NSObject()
        store.addListener(token) { event in
            if case .structure = event { seenStructure = true }
        }
        _ = store.splitPane(session: "work", target: pane.id.raw,
                            horizontal: true, cwd: nil, command: nil)
        XCTAssertTrue(seenStructure, "structural mutation must ping the refresh pipeline")
        store.removeListener(token)
    }
}

/// The view model's store-direct plumbing: attach publishes panes, store
/// mutations flow into the published arrays, and the cross-session move
/// keeps the placeholder-cleanup + follow semantics.
@MainActor
final class WorkspaceViewModelTests: XCTestCase {
    private static let persistKey = "acp_workspace_vm_test"
    private var store: AgentWorkspaceStore!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
        store = AgentWorkspaceStore(persistKey: Self.persistKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
    }

    private func makeVM() -> WorkspaceViewModel {
        WorkspaceViewModel(host: Host(name: "Test"), workspace: store,
                           environment: WorkspaceEnvironment())
    }

    func testAttachPublishesPanes() async {
        let vm = makeVM()
        await vm.start(.createOrAttach(name: "work"))
        XCTAssertTrue(vm.isSessionReady)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.paneViewModels.count, 1)
        XCTAssertEqual(vm.activeSessionName, "work")
        XCTAssertNotNil(vm.activePaneID)
        XCTAssertEqual(vm.availableSessions, ["work"])
        vm.disconnect()
    }

    func testStoreMutationsFlowIntoPublishedPanes() async {
        let vm = makeVM()
        await vm.start(.createOrAttach(name: "work"))
        vm.splitPane(horizontal: true)
        await vm.refreshPanes()
        XCTAssertEqual(vm.paneViewModels.count, 2)
        XCTAssertEqual(vm.sessionPanes.count, 2)
        // The new pane landed focused; zoom flag mirrors the store.
        let active = vm.activePaneID!
        vm.toggleZoom(active)
        await vm.refreshPanes()
        XCTAssertEqual(vm.zoomedPaneID, active)
        vm.disconnect()
    }

    func testMoveLastPaneFollowsAndPrunesPlaceholder() async {
        let vm = makeVM()
        await vm.start(.createOrAttach(name: "source"))
        let only = vm.paneViewModels[0].paneID
        let moved = await vm.movePane(only, toSession: "target")
        XCTAssertTrue(moved)
        XCTAssertNil(store.session("source"), "emptied source session dies")
        XCTAssertEqual(vm.activeSessionName, "target", "client follows its last pane")
        XCTAssertEqual(store.paneList(session: "target").map(\.id), [only],
                       "fresh target holds exactly the moved pane (placeholder pruned)")
        vm.disconnect()
    }
}
