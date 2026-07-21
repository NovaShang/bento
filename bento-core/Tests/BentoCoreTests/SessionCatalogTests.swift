import XCTest
@testable import BentoCore

/// The session-history catalog (docs/session-history-design.md v3):
/// pure merge semantics, plus the store's graduation / filter / reopen
/// plumbing. No launcher is injected — panes get their ACP session ids
/// stamped through noteSpawned, the same door the spawn path uses.
final class SessionCatalogMergeTests: XCTestCase {
    private func entry(_ id: String, cwd: String = "/tmp", title: String = "t",
                       lastActive: Date) -> CatalogEntry {
        CatalogEntry(acpSessionID: id, title: title, presetID: "opencode",
                     cwd: cwd, createdAt: lastActive, lastActive: lastActive)
    }

    func testMergeIsUnion() {
        let t = Date()
        var mine = SessionCatalog()
        mine.upsert(acpSessionID: "a", title: "A", presetID: "p", cwd: "/a", lastActive: t)
        var theirs = SessionCatalog()
        theirs.upsert(acpSessionID: "b", title: "B", presetID: "p", cwd: "/b", lastActive: t)
        mine.merge(theirs)
        XCTAssertEqual(Set(mine.entries.keys), ["a", "b"], "no side's entries may drop")
    }

    func testMergeNewerLastActiveWins() {
        let old = Date(timeIntervalSinceNow: -100)
        let new = Date()
        var mine = SessionCatalog()
        mine.upsert(acpSessionID: "s", title: "stale", presetID: "p", cwd: "/old", lastActive: old)
        var theirs = SessionCatalog()
        theirs.upsert(acpSessionID: "s", title: "fresh", presetID: "p", cwd: "/new", lastActive: new)
        mine.merge(theirs)
        XCTAssertEqual(mine.entries["s"]?.title, "fresh")
        XCTAssertEqual(mine.entries["s"]?.cwd, "/new")
        XCTAssertEqual(mine.entries["s"]?.lastActive, new)

        // And the mirror image: merging a STALE remote must not regress.
        var fresh = SessionCatalog()
        fresh.upsert(acpSessionID: "s", title: "fresh", presetID: "p", cwd: "/new", lastActive: new)
        var stale = SessionCatalog()
        stale.upsert(acpSessionID: "s", title: "stale", presetID: "p", cwd: "/old", lastActive: old)
        fresh.merge(stale)
        XCTAssertEqual(fresh.entries["s"]?.title, "fresh")
    }

    func testMergeExpiredIsSticky() {
        let old = Date(timeIntervalSinceNow: -100)
        let new = Date()
        // The side that saw the expiry is OLDER — expiry must still survive.
        var mine = SessionCatalog()
        mine.upsert(acpSessionID: "s", title: "t", presetID: "p", cwd: "/x", lastActive: old)
        mine.markExpired("s")
        var theirs = SessionCatalog()
        theirs.upsert(acpSessionID: "s", title: "t2", presetID: "p", cwd: "/x", lastActive: new)
        mine.merge(theirs)
        XCTAssertEqual(mine.entries["s"]?.expired, true, "expired is sticky across merges")
        XCTAssertEqual(mine.entries["s"]?.title, "t2", "other fields still follow the newer side")
    }

    func testUpsertNeverMovesLastActiveBackwards() {
        let new = Date()
        var catalog = SessionCatalog()
        catalog.upsert(acpSessionID: "s", title: "t", presetID: "p", cwd: "/x", lastActive: new)
        catalog.upsert(acpSessionID: "s", title: "t", presetID: "p", cwd: "/x",
                       lastActive: Date(timeIntervalSinceNow: -50))
        XCTAssertEqual(catalog.entries["s"]?.lastActive, new)
    }

    func testDecodeToleratesMissingFields() throws {
        // A future (or past) writer that only knows the id must still decode.
        let json = #"{"entries":{"s1":{"acpSessionID":"s1"}}}"#
        let catalog = try JSONDecoder().decode(SessionCatalog.self, from: Data(json.utf8))
        XCTAssertNotNil(catalog.entries["s1"])
        XCTAssertEqual(catalog.entries["s1"]?.expired, false)
    }

    func testListFiltersByCwdExactAndSubtree() {
        let t = Date()
        var catalog = SessionCatalog()
        catalog.upsert(acpSessionID: "root", title: "r", presetID: "p", cwd: "/proj", lastActive: t)
        catalog.upsert(acpSessionID: "sub", title: "s", presetID: "p", cwd: "/proj/api",
                       lastActive: t.addingTimeInterval(1))
        catalog.upsert(acpSessionID: "other", title: "o", presetID: "p", cwd: "/elsewhere",
                       lastActive: t)
        // Sibling with a shared string prefix must NOT match the subtree.
        catalog.upsert(acpSessionID: "prefix", title: "x", presetID: "p", cwd: "/project",
                       lastActive: t)

        XCTAssertEqual(catalog.list(cwd: "/proj").map(\.acpSessionID), ["root"])
        XCTAssertEqual(Set(catalog.list(cwd: "/proj", subtree: true).map(\.acpSessionID)),
                       ["root", "sub"])
        XCTAssertEqual(catalog.list(cwd: "/proj/", subtree: true).count, 2,
                       "trailing slash normalizes away")
        XCTAssertEqual(catalog.list().count, 4)
        XCTAssertEqual(catalog.list().first?.acpSessionID, "sub", "newest activity first")
    }
}

/// The store side: graduation on pane close, reopen-as-pane, live badge
/// sources, and removal.
@MainActor
final class SessionCatalogStoreTests: XCTestCase {
    private static let persistKey = "acp_workspace_catalog_test"
    private var store: AgentWorkspaceStore!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
        UserDefaults.standard.removeObject(
            forKey: AgentWorkspaceStore.catalogKey(forWorkspaceKey: Self.persistKey))
        store = AgentWorkspaceStore(persistKey: Self.persistKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
        UserDefaults.standard.removeObject(
            forKey: AgentWorkspaceStore.catalogKey(forWorkspaceKey: Self.persistKey))
    }

    private func firstPane(_ name: String = "work") -> Int {
        _ = store.ensureSession(name)
        return store.paneList(session: name)[0].id.raw
    }

    func testKilledPaneGraduatesIntoCatalog() {
        let pane = firstPane()
        _ = store.splitPane(session: "work", target: pane, horizontal: true,
                            cwd: "/tmp/side", command: nil)
        let side = store.paneList(session: "work").first { $0.id.raw != pane }!.id.raw
        store.noteSpawned(paneID: side, instanceID: nil, acpSessionID: "sess-side")
        store.killPane(side)
        XCTAssertEqual(store.catalogEntries().map(\.acpSessionID), ["sess-side"],
                       "closing a pane keeps its conversation reachable")
        XCTAssertEqual(store.catalogEntries()[0].cwd, "/tmp/side")
    }

    func testKilledSessionGraduatesEveryPane() {
        let pane = firstPane()
        store.noteSpawned(paneID: pane, instanceID: nil, acpSessionID: "sess-1")
        _ = store.splitPane(session: "work", target: pane, horizontal: true,
                            cwd: nil, command: nil)
        let second = store.paneList(session: "work").first { $0.id.raw != pane }!.id.raw
        store.noteSpawned(paneID: second, instanceID: nil, acpSessionID: "sess-2")
        store.killSession("work")
        XCTAssertEqual(Set(store.catalogEntries().map(\.acpSessionID)), ["sess-1", "sess-2"])
    }

    func testLiveSessionAppearsWithLiveBadgeSource() {
        let pane = firstPane()
        store.noteSpawned(paneID: pane, instanceID: nil, acpSessionID: "sess-live")
        XCTAssertEqual(store.catalogEntries().map(\.acpSessionID), ["sess-live"],
                       "a session exists in history from birth")
        XCTAssertEqual(store.liveSessionIDs, ["sess-live"])
        XCTAssertEqual(store.paneID(forACPSession: "sess-live"), pane)
    }

    func testCwdFilterThroughStore() {
        let pane = firstPane()
        _ = store.splitPane(session: "work", target: pane, horizontal: true,
                            cwd: "/proj/api", command: nil)
        let sub = store.paneList(session: "work").first { $0.id.raw != pane }!.id.raw
        store.noteSpawned(paneID: sub, instanceID: nil, acpSessionID: "sess-sub")
        _ = store.newPane(session: "work", cwd: "/proj", command: nil)
        let root = store.paneList(session: "work").map(\.id.raw)
            .first { $0 != pane && $0 != sub }!
        store.noteSpawned(paneID: root, instanceID: nil, acpSessionID: "sess-root")

        XCTAssertEqual(store.catalogEntries(cwd: "/proj").map(\.acpSessionID), ["sess-root"])
        XCTAssertEqual(Set(store.catalogEntries(cwd: "/proj", subtree: true).map(\.acpSessionID)),
                       ["sess-root", "sess-sub"])
    }

    func testOpenHistorySessionBuildsPrefilledPane() {
        _ = firstPane()
        let entry = CatalogEntry(
            acpSessionID: "sess-old", title: "fix the tests", presetID: "opencode",
            cwd: "/tmp/proj", createdAt: Date(), lastActive: Date())
        let opened = store.openHistorySession(entry, inSession: "work")
        XCTAssertNotNil(opened)
        let pane = store.paneEntry(opened!)
        XCTAssertEqual(pane?.acpSessionID, "sess-old", "spawn resumes through session/load")
        XCTAssertEqual(pane?.cwd, "/tmp/proj")
        XCTAssertEqual(pane?.presetID, "opencode")
        XCTAssertNil(pane?.instanceID, "no instance: spawn takes the fresh-launch path")
        XCTAssertEqual(store.session("work")?.activePane, opened, "reopened pane lands focused")
        XCTAssertEqual(store.paneList(session: "work").count, 2)
    }

    func testOpenHistorySessionRestoresCustomCommand() {
        _ = firstPane()
        let entry = CatalogEntry(
            acpSessionID: "sess-c", title: "t", presetID: "custom:mytool --acp",
            cwd: "/tmp", createdAt: Date(), lastActive: Date())
        let opened = store.openHistorySession(entry, inSession: "work")
        let pane = store.paneEntry(opened!)
        XCTAssertEqual(pane?.customPreset?.command, "mytool")
        XCTAssertEqual(pane?.startCommand, "mytool --acp",
                       "the command text round-trips through the custom preset id")
    }

    func testOpenHistorySessionFocusesLivePaneInsteadOfDuplicating() {
        let pane = firstPane()
        _ = store.splitPane(session: "work", target: pane, horizontal: true,
                            cwd: nil, command: nil)
        store.noteSpawned(paneID: pane, instanceID: nil, acpSessionID: "sess-live")
        let entry = store.catalogEntries()[0]
        let before = store.paneList(session: "work").count
        let opened = store.openHistorySession(entry, inSession: "work")
        XCTAssertEqual(opened, pane, "a live session focuses its pane")
        XCTAssertEqual(store.paneList(session: "work").count, before,
                       "no duplicate pane may drive the same ACP session")
        XCTAssertEqual(store.session("work")?.activePane, pane)
    }

    func testRemoveAndMarkExpired() {
        let pane = firstPane()
        store.noteSpawned(paneID: pane, instanceID: nil, acpSessionID: "sess-x")
        store.markExpired("sess-x")
        XCTAssertEqual(store.catalogEntries()[0].expired, true)
        store.removeCatalogEntry("sess-x")
        XCTAssertTrue(store.catalogEntries().isEmpty)
    }
}
