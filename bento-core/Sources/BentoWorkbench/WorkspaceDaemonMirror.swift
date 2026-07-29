import BentoFoundation
import BentoUI
import Foundation

/// Wire types for the per-session daemon statekv mirror.
///
/// The workspace used to live in the daemon as ONE blob under "workspace",
/// written fire-and-forget by whichever device saved last. Two devices
/// editing DIFFERENT sessions clobbered each other's whole tree — the exact
/// failure the Mac↔phone handoff story can't afford. The mirror now writes
/// one key per session plus a small index:
///
///   workspace/index   → WorkspaceIndex {rev, origin, order, counters}
///   workspace/s/<id>  → SessionEnvelope {rev, origin, session}
///
/// Concurrency model: per-key last-write-wins, guarded by a monotonically
/// increasing `rev` so a device never adopts something older than what it
/// already has, with `origin` (a per-launch UUID) as the deterministic
/// tie-break when two devices race the same rev — both sides pick the same
/// winner, so the fleet converges. Cross-SESSION edits never conflict at
/// all anymore; same-session races lose one edit (accepted — you're rarely
/// editing one session from two hands).
///
/// Deletion has no tombstones: a session missing from the index is removed
/// only when the local copy has no unpushed edits; otherwise the local copy
/// is pushed back (resurrection over silent loss).
package enum WorkspaceMirror {
    static let indexKey = "workspace/index"
    static let sessionKeyPrefix = "workspace/s/"

    static func sessionKey(_ id: Int) -> String { sessionKeyPrefix + String(id) }

    /// What actually crosses the wire. View state — which pane is focused,
    /// which is zoomed, how big this device's canvas is — belongs to the
    /// device looking at the workspace, not to the workspace. Mirroring it
    /// did two kinds of damage: every click became a cross-device write (and
    /// a rev bump that could lose a real layout edit to a same-rev race), and
    /// adopting one yanked the other device's focus mid-read.
    ///
    /// Normalized rather than dropped, so the envelope's shape is unchanged
    /// and older peers keep decoding it — they simply receive a constant.
    static func sharedProjection(
        of entry: AgentWorkspaceStore.WorkspaceEntry
    ) -> AgentWorkspaceStore.WorkspaceEntry {
        var shared = entry
        shared.activePane = 0
        shared.zoomedPane = nil
        shared.cols = AgentWorkspaceStore.defaultCols
        shared.rows = AgentWorkspaceStore.defaultRows
        return shared
    }

    /// Keep this device's view state across an adopt, and make sure whatever
    /// survives still names a pane that exists — the peer may have killed the
    /// one we were looking at.
    static func restoreViewState(
        into incoming: inout AgentWorkspaceStore.WorkspaceEntry,
        from local: AgentWorkspaceStore.WorkspaceEntry?
    ) {
        if let local {
            incoming.activePane = local.activePane
            incoming.zoomedPane = local.zoomedPane
            incoming.cols = local.cols
            incoming.rows = local.rows
        }
        if !incoming.panes.contains(where: { $0.id == incoming.activePane }) {
            incoming.activePane = incoming.panes.first?.id ?? 0
        }
        if let zoomed = incoming.zoomedPane,
           !incoming.panes.contains(where: { $0.id == zoomed }) {
            incoming.zoomedPane = nil
        }
    }

    static func sessionID(fromKey key: String) -> Int? {
        guard key.hasPrefix(sessionKeyPrefix) else { return nil }
        return Int(key.dropFirst(sessionKeyPrefix.count))
    }

    package struct SessionEnvelope: Codable {
        package var rev: Int
        package var origin: String
        package var session: AgentWorkspaceStore.WorkspaceEntry

        package init(rev: Int, origin: String,
                     session: AgentWorkspaceStore.WorkspaceEntry) {
            self.rev = rev
            self.origin = origin
            self.session = session
        }
    }

    package struct WorkspaceIndex: Codable {
        package var schema = 3
        package var rev: Int
        package var origin: String
        package var order: [Int]
        package var nextPane: Int
        package var nextSession: Int

        package init(schema: Int = 3, rev: Int, origin: String, order: [Int],
                     nextPane: Int, nextSession: Int) {
            self.schema = schema
            self.rev = rev
            self.origin = origin
            self.order = order
            self.nextPane = nextPane
            self.nextSession = nextSession
        }
    }

    /// (rev, origin) ordering: adopt the remote copy iff it wins this.
    package static func remoteWins(remoteRev: Int, remoteOrigin: String,
                           localRev: Int, localOrigin: String) -> Bool {
        if remoteRev != localRev { return remoteRev > localRev }
        return remoteOrigin > localOrigin
    }
}

/// Mutable bookkeeping for the mirror, boxed so the store body only adds
/// one stored property.
@MainActor
package final class WorkspaceMirrorState {
    /// Per-launch identity, used only for same-rev tie-breaks.
    let origin = UUID().uuidString
    /// Last-pushed encoded WorkspaceEntry per session id (rev/origin excluded
    /// so the dirty check compares content only).
    var pushedSessions: [Int: Data] = [:]
    /// The rev each session is known to be at (ours or adopted).
    package var sessionRevs: [Int: Int] = [:]
    /// Comparator encoding of the last-pushed index (rev=0, origin empty).
    var pushedIndex: Data?
    package var indexRev = 0

    /// True when the local copy of `session` differs from what was last
    /// pushed (i.e. there are local edits in flight).
    /// Record what the wire now holds for this session. One place, so no
    /// caller — production or test — can disagree with `isDirty` about what
    /// "pushed" means.
    package func notePushed(_ session: AgentWorkspaceStore.WorkspaceEntry) {
        pushedSessions[session.id] = try? JSONEncoder().encode(
            WorkspaceMirror.sharedProjection(of: session))
    }

    package func isDirty(_ session: AgentWorkspaceStore.WorkspaceEntry) -> Bool {
        guard let plain = try? JSONEncoder().encode(
            WorkspaceMirror.sharedProjection(of: session)) else { return true }
        return pushedSessions[session.id] != plain
    }
}
