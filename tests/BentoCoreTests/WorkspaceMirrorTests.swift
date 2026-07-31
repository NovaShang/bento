import XCTest
@testable import BentoCore

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

    private func workspace(_ name: String) -> AgentWorkspaceStore.WorkspaceEntry? {
        store.state.sessions.first { $0.name == name }
    }

    private func envelope(rev: Int, origin: String,
                          _ entry: AgentWorkspaceStore.WorkspaceEntry) -> WorkspaceMirror.SessionEnvelope {
        WorkspaceMirror.SessionEnvelope(rev: rev, origin: origin, session: entry)
    }

    private func remoteCopy(of name: String, renamedTo newName: String? = nil)
        -> AgentWorkspaceStore.WorkspaceEntry {
        var copy = workspace(name)!
        if let newName { copy.name = newName }
        return copy
    }

    // MARK: - View state is this device's, not the workspace's

    /// A peer's focus must not move ours. Adopting it yanked the pane the
    /// other person was reading, mid-read.
    func testAdoptKeepsThisDevicesFocusAndZoom() {
        _ = store.ensureWorkspace("work")
        let id = workspace("work")!.id
        let second = store.splitPane(session: "work", target: workspace("work")!.panes[0].id,
                                     horizontal: true, cwd: nil, command: nil)!
        store.selectPane(second)
        store.toggleZoom(second)
        XCTAssertEqual(workspace("work")!.activePane, second)
        XCTAssertEqual(workspace("work")!.zoomedPane, second)

        // The peer is looking at the FIRST pane, unzoomed.
        var remote = remoteCopy(of: "work")
        remote.activePane = remote.panes[0].id
        remote.zoomedPane = nil
        remote.name = "work-renamed"
        store.adoptRemoteSession(id, envelope: envelope(rev: 9, origin: "peer", remote))

        XCTAssertEqual(workspace("work-renamed")!.name, "work-renamed", "structure still follows the peer")
        XCTAssertEqual(workspace("work-renamed")!.activePane, second, "our focus stays put")
        XCTAssertEqual(workspace("work-renamed")!.zoomedPane, second, "our zoom stays put")
    }

    /// ...unless the pane we were looking at is gone — then repair rather
    /// than point at nothing.
    func testAdoptRepairsFocusWhenThePeerKilledThatPane() {
        _ = store.ensureWorkspace("work")
        let id = workspace("work")!.id
        let second = store.splitPane(session: "work", target: workspace("work")!.panes[0].id,
                                     horizontal: true, cwd: nil, command: nil)!
        store.selectPane(second)

        var remote = remoteCopy(of: "work")
        remote.panes.removeAll { $0.id == second }
        store.adoptRemoteSession(id, envelope: envelope(rev: 9, origin: "peer", remote))

        XCTAssertEqual(workspace("work")!.activePane, workspace("work")!.panes[0].id,
                       "focus falls back to a pane that exists")
    }

    /// Clicking around is not an edit. Before this, every focus change wrote
    /// a new rev — which could lose a peer's real layout edit to a same-rev
    /// race, and reordered the session list by "activity" on a mere glance.
    func testFocusChangesAreNotAnUnpushedEdit() {
        _ = store.ensureWorkspace("work")
        let first = workspace("work")!.panes[0].id
        let second = store.splitPane(session: "work", target: first,
                                     horizontal: true, cwd: nil, command: nil)!
        store.mirror.notePushed(workspace("work")!)
        let stampBefore = workspace("work")!.lastActivity

        store.selectPane(first)
        store.toggleZoom(first)
        store.selectPane(second)

        XCTAssertFalse(store.mirror.isDirty(workspace("work")!),
                       "focus and zoom must not read as an unpushed edit")
        XCTAssertEqual(workspace("work")!.lastActivity, stampBefore,
                       "glancing at a pane is not activity")
    }

    /// But a real structural edit still is one.
    func testStructuralEditIsStillDirty() {
        _ = store.ensureWorkspace("work")
        store.mirror.notePushed(workspace("work")!)
        store.renameSession("work", to: "work2")
        XCTAssertTrue(store.mirror.isDirty(workspace("work2")!))
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
        _ = store.ensureWorkspace("work")
        let id = workspace("work")!.id
        store.mirror.sessionRevs[id] = 5
        store.adoptRemoteSession(id, envelope: envelope(rev: 4, origin: "zzz",
                                                        remoteCopy(of: "work", renamedTo: "stale")))
        XCTAssertEqual(workspace("work")?.name, "work", "older rev must not clobber")
    }

    func testNewerRemoteSessionAdopted() {
        _ = store.ensureWorkspace("work")
        let id = workspace("work")!.id
        store.mirror.sessionRevs[id] = 2
        store.adoptRemoteSession(id, envelope: envelope(rev: 3, origin: "peer",
                                                        remoteCopy(of: "work", renamedTo: "renamed")))
        XCTAssertEqual(store.state.sessions.first { $0.id == id }?.name, "renamed")
        XCTAssertEqual(store.mirror.sessionRevs[id], 3, "adopting records the remote rev")
    }

    func testAdoptingOneSessionLeavesOthersUntouched() {
        _ = store.ensureWorkspace("alpha")
        _ = store.ensureWorkspace("beta")
        let alphaID = workspace("alpha")!.id
        let betaPanesBefore = workspace("beta")!.panes.map(\.id)
        store.adoptRemoteSession(alphaID, envelope: envelope(rev: 9, origin: "peer",
                                                             remoteCopy(of: "alpha", renamedTo: "alpha2")))
        XCTAssertEqual(workspace("beta")!.panes.map(\.id), betaPanesBefore,
                       "cross-session isolation: adopting alpha never touches beta")
        XCTAssertNotNil(store.state.sessions.first { $0.name == "alpha2" })
    }

    func testUnknownRemoteSessionAppends() {
        _ = store.ensureWorkspace("local")
        var foreign = remoteCopy(of: "local")
        foreign.id = 999
        foreign.name = "from-peer"
        store.adoptRemoteSession(999, envelope: envelope(rev: 1, origin: "peer", foreign))
        XCTAssertEqual(store.state.sessions.count, 2)
        XCTAssertNotNil(workspace("from-peer"))
    }

    // MARK: - Remote deletion vs local dirty edits

    func testRemoteDeleteDropsCleanLocalSession() {
        _ = store.ensureWorkspace("work")
        let id = workspace("work")!.id
        // Mark as pushed (clean): cache the current encoding.
        store.mirror.notePushed(workspace("work")!)
        store.handleRemoteSessionMissing(id)
        XCTAssertNil(workspace("work"), "clean session follows the remote delete")
    }

    func testRemoteDeleteSparesDirtyLocalSession() {
        // Post-adoption: this device has a baseline from the daemon, so an
        // unpushed difference really is an edit made here.
        store.structureAdopted = true
        _ = store.ensureWorkspace("work")
        let id = workspace("work")!.id
        // No pushed cache entry → the local copy has unpushed edits (dirty).
        store.handleRemoteSessionMissing(id)
        XCTAssertNotNil(workspace("work"),
                        "unpushed local edits survive a remote delete (resurrection over loss)")
    }

    /// The same input before the first sync means the opposite thing. What
    /// this store holds is the render cache, `pushedSessions` is empty so
    /// EVERY session reads as dirty, and honouring that exemption is how a
    /// laptop that had been closed for a week reinstated workspaces the
    /// others had closed.
    func testRemoteDeleteDropsCachedSessionBeforeAdoption() {
        XCTAssertFalse(store.structureAdopted)
        _ = store.ensureWorkspace("work")
        let id = workspace("work")!.id
        store.handleRemoteSessionMissing(id)
        XCTAssertNil(workspace("work"),
                     "before the first adopt there are no local edits, only cache")
    }

    // MARK: - Index application

    private func indexData(rev: Int, origin: String, order: [Int],
                           nextPane: Int = 100, nextSession: Int = 50) -> Data {
        try! JSONEncoder().encode(WorkspaceMirror.WorkspaceIndex(
            rev: rev, origin: origin, order: order,
            nextPane: nextPane, nextSession: nextSession))
    }

    func testIndexReordersAndGrowsCounters() async {
        _ = store.ensureWorkspace("a")
        _ = store.ensureWorkspace("b")
        let aID = workspace("a")!.id, bID = workspace("b")!.id
        await store.applyRemoteIndex(indexData(rev: 1, origin: "peer", order: [bID, aID]))
        XCTAssertEqual(store.state.sessions.map(\.id), [bID, aID], "remote order adopted")
        XCTAssertEqual(store.state.nextPane, 100, "counters only grow (max)")
        await store.applyRemoteIndex(indexData(rev: 2, origin: "peer", order: [bID, aID], nextPane: 3))
        XCTAssertEqual(store.state.nextPane, 100, "a stale counter never shrinks ids")
    }

    func testStaleIndexIgnored() async {
        _ = store.ensureWorkspace("a")
        let aID = workspace("a")!.id
        store.mirror.indexRev = 10
        await store.applyRemoteIndex(indexData(rev: 9, origin: "zzz", order: []))
        XCTAssertNotNil(workspace("a"), "an older index must not delete sessions")
    }

    func testIndexRemovesCleanKeepsDirty() async {
        store.structureAdopted = true
        _ = store.ensureWorkspace("clean")
        _ = store.ensureWorkspace("dirty")
        let cleanID = workspace("clean")!.id
        let dirtyID = workspace("dirty")!.id
        store.mirror.notePushed(workspace("clean")!)
        // Index from a peer that lists neither session.
        await store.applyRemoteIndex(indexData(rev: 1, origin: "peer", order: []))
        XCTAssertNil(workspace("clean"), "pushed-and-unchanged session follows the index")
        XCTAssertNotNil(workspace("dirty"), "dirty session survives to be re-pushed")
        XCTAssertEqual(store.state.sessions.map(\.id), [dirtyID])
    }

    /// Same index, same two sessions, but before the first adopt: an index
    /// that lists neither means both were closed elsewhere, and neither may
    /// survive on the strength of being "unpushed".
    func testIndexRemovesEverythingUnlistedBeforeAdoption() async {
        XCTAssertFalse(store.structureAdopted)
        _ = store.ensureWorkspace("clean")
        _ = store.ensureWorkspace("dirty")
        store.mirror.notePushed(workspace("clean")!)
        await store.applyRemoteIndex(indexData(rev: 1, origin: "peer", order: []))
        XCTAssertTrue(store.state.sessions.isEmpty,
                      "the cache does not get to outvote the daemon's membership")
    }

    // MARK: - The cache is never a basis for a write

    /// The invariant that makes the rest of it hold: whatever this store is
    /// showing before the first sync, it publishes none of it.
    func testMirrorRefusesToPushBeforeAdoption() {
        _ = store.ensureWorkspace("work")
        XCTAssertFalse(store.structureAdopted)
        store.mirrorToDaemon()
        XCTAssertTrue(store.mirror.isDirty(workspace("work")!),
                      "nothing was pushed, so the session is still unrecorded")
    }
}
