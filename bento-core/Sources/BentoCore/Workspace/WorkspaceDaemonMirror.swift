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
enum WorkspaceMirror {
    static let indexKey = "workspace/index"
    static let sessionKeyPrefix = "workspace/s/"

    static func sessionKey(_ id: Int) -> String { sessionKeyPrefix + String(id) }

    static func sessionID(fromKey key: String) -> Int? {
        guard key.hasPrefix(sessionKeyPrefix) else { return nil }
        return Int(key.dropFirst(sessionKeyPrefix.count))
    }

    struct SessionEnvelope: Codable {
        var rev: Int
        var origin: String
        var session: AgentWorkspaceStore.WorkspaceEntry
    }

    struct WorkspaceIndex: Codable {
        var schema = 3
        var rev: Int
        var origin: String
        var order: [Int]
        var nextPane: Int
        var nextSession: Int
    }

    /// (rev, origin) ordering: adopt the remote copy iff it wins this.
    static func remoteWins(remoteRev: Int, remoteOrigin: String,
                           localRev: Int, localOrigin: String) -> Bool {
        if remoteRev != localRev { return remoteRev > localRev }
        return remoteOrigin > localOrigin
    }
}

/// Mutable bookkeeping for the mirror, boxed so the store body only adds
/// one stored property.
@MainActor
final class WorkspaceMirrorState {
    /// Per-launch identity, used only for same-rev tie-breaks.
    let origin = UUID().uuidString
    /// Last-pushed encoded WorkspaceEntry per session id (rev/origin excluded
    /// so the dirty check compares content only).
    var pushedSessions: [Int: Data] = [:]
    /// The rev each session is known to be at (ours or adopted).
    var sessionRevs: [Int: Int] = [:]
    /// Comparator encoding of the last-pushed index (rev=0, origin empty).
    var pushedIndex: Data?
    var indexRev = 0

    /// True when the local copy of `session` differs from what was last
    /// pushed (i.e. there are local edits in flight).
    func isDirty(_ session: AgentWorkspaceStore.WorkspaceEntry) -> Bool {
        guard let plain = try? JSONEncoder().encode(session) else { return true }
        return pushedSessions[session.id] != plain
    }
}
