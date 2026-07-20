import XCTest
@testable import BentoTerminalCore

/// Merge semantics of the per-session daemon mirror: (rev, origin)
/// guarding, cross-session isolation, dirty-local survival, and index
/// membership/ordering — the machinery that replaced whole-blob
/// last-write-wins (which let two devices clobber each other's tree).
@MainActor
final class WorkspaceMirrorTests: XCTestCase {
    private static let persistKey = "acp_workspace_mirror_test"
    private var store: AgentWorkspaceStore!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
        store = AgentWorkspaceStore(persistKey: Self.persistKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
    }

    private func session(_ name: String) -> AgentWorkspaceStore.SessionEntry? {
        store.state.sessions.first { $0.name == name }
    }

    private func envelope(rev: Int, origin: String,
                          _ entry: AgentWorkspaceStore.SessionEntry) -> WorkspaceMirror.SessionEnvelope {
        WorkspaceMirror.SessionEnvelope(rev: rev, origin: origin, session: entry)
    }

    private func remoteCopy(of name: String, renamedTo newName: String? = nil)
        -> AgentWorkspaceStore.SessionEntry {
        var copy = session(name)!
        if let newName { copy.name = newName }
        return copy
    }

    // MARK: - remoteWins ordering

    func testRemoteWinsOrdering() {
        XCTAssertTrue(WorkspaceMirror.remoteWins(remoteRev: 2, remoteOrigin: "a",
                                                 localRev: 1, localOrigin: "z"))
        XCTAssertFalse(WorkspaceMirror.remoteWins(remoteRev: 1, remoteOrigin: "z",
                                                  localRev: 2, localOrigin: "a"))
        // Tie on rev: origin breaks it, and BOTH sides agree on the winner.
        XCTAssertTrue(WorkspaceMirror.remoteWins(remoteRev: 3, remoteOrigin: "b",
                                                 localRev: 3, localOrigin: "a"))
        XCTAssertFalse(WorkspaceMirror.remoteWins(remoteRev: 3, remoteOrigin: "a",
                                                  localRev: 3, localOrigin: "b"))
    }

    // MARK: - Session adoption

    func testStaleRemoteSessionIgnored() {
        _ = store.ensureSession("work")
        let id = session("work")!.id
        store.mirror.sessionRevs[id] = 5
        store.adoptRemoteSession(id, envelope: envelope(rev: 4, origin: "zzz",
                                                        remoteCopy(of: "work", renamedTo: "stale")))
        XCTAssertEqual(session("work")?.name, "work", "older rev must not clobber")
    }

    func testNewerRemoteSessionAdopted() {
        _ = store.ensureSession("work")
        let id = session("work")!.id
        store.mirror.sessionRevs[id] = 2
        store.adoptRemoteSession(id, envelope: envelope(rev: 3, origin: "peer",
                                                        remoteCopy(of: "work", renamedTo: "renamed")))
        XCTAssertEqual(store.state.sessions.first { $0.id == id }?.name, "renamed")
        XCTAssertEqual(store.mirror.sessionRevs[id], 3, "adopting records the remote rev")
    }

    func testAdoptingOneSessionLeavesOthersUntouched() {
        _ = store.ensureSession("alpha")
        _ = store.ensureSession("beta")
        let alphaID = session("alpha")!.id
        let betaPanesBefore = session("beta")!.panes.map(\.id)
        store.adoptRemoteSession(alphaID, envelope: envelope(rev: 9, origin: "peer",
                                                             remoteCopy(of: "alpha", renamedTo: "alpha2")))
        XCTAssertEqual(session("beta")!.panes.map(\.id), betaPanesBefore,
                       "cross-session isolation: adopting alpha never touches beta")
        XCTAssertNotNil(store.state.sessions.first { $0.name == "alpha2" })
    }

    func testUnknownRemoteSessionAppends() {
        _ = store.ensureSession("local")
        var foreign = remoteCopy(of: "local")
        foreign.id = 999
        foreign.name = "from-peer"
        store.adoptRemoteSession(999, envelope: envelope(rev: 1, origin: "peer", foreign))
        XCTAssertEqual(store.state.sessions.count, 2)
        XCTAssertNotNil(session("from-peer"))
    }

    // MARK: - Remote deletion vs local dirty edits

    func testRemoteDeleteDropsCleanLocalSession() {
        _ = store.ensureSession("work")
        let id = session("work")!.id
        // Mark as pushed (clean): cache the current encoding.
        store.mirror.pushedSessions[id] = try? JSONEncoder().encode(session("work")!)
        store.handleRemoteSessionMissing(id)
        XCTAssertNil(session("work"), "clean session follows the remote delete")
    }

    func testRemoteDeleteSparesDirtyLocalSession() {
        _ = store.ensureSession("work")
        let id = session("work")!.id
        // No pushed cache entry → the local copy has unpushed edits (dirty).
        store.handleRemoteSessionMissing(id)
        XCTAssertNotNil(session("work"),
                        "unpushed local edits survive a remote delete (resurrection over loss)")
    }

    // MARK: - Index application

    private func indexData(rev: Int, origin: String, order: [Int],
                           nextPane: Int = 100, nextSession: Int = 50) -> Data {
        try! JSONEncoder().encode(WorkspaceMirror.WorkspaceIndex(
            rev: rev, origin: origin, order: order,
            nextPane: nextPane, nextSession: nextSession))
    }

    func testIndexReordersAndGrowsCounters() async {
        _ = store.ensureSession("a")
        _ = store.ensureSession("b")
        let aID = session("a")!.id, bID = session("b")!.id
        await store.applyRemoteIndex(indexData(rev: 1, origin: "peer", order: [bID, aID]))
        XCTAssertEqual(store.state.sessions.map(\.id), [bID, aID], "remote order adopted")
        XCTAssertEqual(store.state.nextPane, 100, "counters only grow (max)")
        await store.applyRemoteIndex(indexData(rev: 2, origin: "peer", order: [bID, aID], nextPane: 3))
        XCTAssertEqual(store.state.nextPane, 100, "a stale counter never shrinks ids")
    }

    func testStaleIndexIgnored() async {
        _ = store.ensureSession("a")
        let aID = session("a")!.id
        store.mirror.indexRev = 10
        await store.applyRemoteIndex(indexData(rev: 9, origin: "zzz", order: []))
        XCTAssertNotNil(session("a"), "an older index must not delete sessions")
    }

    func testIndexRemovesCleanKeepsDirty() async {
        _ = store.ensureSession("clean")
        _ = store.ensureSession("dirty")
        let cleanID = session("clean")!.id
        let dirtyID = session("dirty")!.id
        store.mirror.pushedSessions[cleanID] = try? JSONEncoder().encode(session("clean")!)
        // Index from a peer that lists neither session.
        await store.applyRemoteIndex(indexData(rev: 1, origin: "peer", order: []))
        XCTAssertNil(session("clean"), "pushed-and-unchanged session follows the index")
        XCTAssertNotNil(session("dirty"), "dirty session survives to be re-pushed")
        XCTAssertEqual(store.state.sessions.map(\.id), [dirtyID])
    }
}
