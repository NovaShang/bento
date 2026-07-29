import XCTest
import BentoTerminalPane
import BentoWorkbench
@testable import BentoTmuxPane

// The store-level integration test the acceptance names: DaemonAuthority.ingest
// → workspace projection → store adoption → paneList, with the tmux pane module
// installed so each projected pane gets a live TmuxPaneRuntime. This is the
// headless twin of the AppKit shell's store↔daemon path (the shell's
// TerminalViewModel adapter does exactly this over a real socket; here the transport
// is InMemoryTmuxTransport so it runs in CI with no daemon).
@MainActor
final class StoreProjectionIntegrationTests: XCTestCase {

    /// A recording encoding — the write path isn't under test here.
    private struct NoopEncoding: StructureVerbEncoding {
        func encodeStructureFrame(_ verb: StructureVerb) throws -> Data { Data() }
    }

    private func freshStore() -> AgentWorkspaceStore {
        // Unique key per test so UserDefaults state never bleeds between runs.
        AgentWorkspaceStore(persistKey: "termtest_\(UUID().uuidString)")
    }

    private func state(rev: UInt64, session: String,
                       windows: [TmuxSnapshotWindow]) -> Data {
        let s = TmuxStructureState(
            rev: rev, target: "local", session: session,
            structure: TmuxStructureSnapshot(windows: windows))
        return try! JSONEncoder().encode(s)
    }

    func testIngestProjectsToPaneListAndBuildsRuntimes() {
        let store = freshStore()
        TmuxPaneModule.install(on: store, registry: PaneModuleRegistry()) { _ in
            InMemoryTmuxTransport()
        }

        let authority = DaemonAuthority(encoding: NoopEncoding(), entryID: 7) { _ in }
        authority.onProjection = { entry, _ in
            store.adoptTmuxProjection(entry)
            store.ensureRuntimes(session: entry.name)
        }

        // One window, two side-by-side panes (%1 left, %2 right).
        let win = TmuxSnapshotWindow(
            index: 0, name: "main", panes: [1, 2],
            details: [
                TmuxSnapshotPane(id: 1, title: "editor", width: 80, height: 24, x: 0, y: 0, active: true),
                TmuxSnapshotPane(id: 2, title: "logs", width: 80, height: 24, x: 81, y: 0),
            ])
        XCTAssertTrue(authority.ingest(stateValue: state(rev: 1, session: "bento", windows: [win])))

        let panes = store.paneList(session: "bento")
        XCTAssertEqual(panes.map(\.id.raw).sorted(), [1, 2])
        XCTAssertEqual(panes.first(where: \.isActive)?.id.raw, 1)
        // The pane kind dispatched through the registry to the tmux module.
        XCTAssertEqual(store.paneKind(1), .tmux)
        // Every pane got a live runtime, and it is the tmux runtime.
        XCTAssertTrue(store.runtime(forPane: 1) is TmuxPaneRuntime)
        XCTAssertTrue(store.runtime(forPane: 2) is TmuxPaneRuntime)
    }

    func testStaleRevIsDropped() {
        let store = freshStore()
        TmuxPaneModule.install(on: store, registry: PaneModuleRegistry()) { _ in InMemoryTmuxTransport() }
        let authority = DaemonAuthority(encoding: NoopEncoding(), entryID: 1) { _ in }
        var projections = 0
        authority.onProjection = { entry, _ in
            projections += 1
            store.adoptTmuxProjection(entry)
        }
        let win = TmuxSnapshotWindow(index: 0, name: "w", panes: [1],
            details: [TmuxSnapshotPane(id: 1, width: 80, height: 24, x: 0, y: 0)])
        XCTAssertTrue(authority.ingest(stateValue: state(rev: 5, session: "s", windows: [win])))
        // A lower rev after a higher one is dropped (statekv is LWW + rev-guarded).
        XCTAssertFalse(authority.ingest(stateValue: state(rev: 4, session: "s", windows: [win])))
        XCTAssertEqual(projections, 1)
    }

    func testVanishedPaneLosesItsRuntime() {
        let store = freshStore()
        TmuxPaneModule.install(on: store, registry: PaneModuleRegistry()) { _ in InMemoryTmuxTransport() }
        let authority = DaemonAuthority(encoding: NoopEncoding(), entryID: 3) { _ in }
        authority.onProjection = { entry, _ in
            store.adoptTmuxProjection(entry)
            store.ensureRuntimes(session: entry.name)
        }
        let two = TmuxSnapshotWindow(index: 0, name: "w", panes: [1, 2],
            details: [
                TmuxSnapshotPane(id: 1, width: 80, height: 24, x: 0, y: 0, active: true),
                TmuxSnapshotPane(id: 2, width: 80, height: 24, x: 81, y: 0),
            ])
        _ = authority.ingest(stateValue: state(rev: 1, session: "s", windows: [two]))
        XCTAssertNotNil(store.runtime(forPane: 2))

        // Next snapshot drops %2 — its runtime is torn down, %1 survives.
        let one = TmuxSnapshotWindow(index: 0, name: "w", panes: [1],
            details: [TmuxSnapshotPane(id: 1, width: 80, height: 24, x: 0, y: 0, active: true)])
        _ = authority.ingest(stateValue: state(rev: 2, session: "s", windows: [one]))
        XCTAssertEqual(store.paneList(session: "s").map(\.id.raw), [1])
        XCTAssertNotNil(store.runtime(forPane: 1))
        XCTAssertNil(store.runtime(forPane: 2))
    }
}
