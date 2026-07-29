import Foundation

// Product B's store-adoption path. A tmux workspace's structure is owned by
// the daemon (docs/tmux-host-design.md "结构镜像"); the client only ever holds
// a READING of it. `DaemonAuthority.ingest` decodes the statekv mirror into a
// projected `WorkspaceEntry` (TmuxStructureProjection), and this swaps that
// entry into the store WHOLESALE — there is nothing to merge, the projection
// is the whole truth. Additive by design: product A never calls it (its
// structure moves through the local verbs + the ACP per-session daemon mirror,
// AgentWorkspaceStore+DaemonSync), so this file changes nothing A does.
extension AgentWorkspaceStore {
    /// Adopt a freshly projected tmux workspace entry, keyed by `entry.id`.
    /// Replaces the session in place (or inserts it), tears down runtimes for
    /// panes the mirror no longer lists (their tmux pane is gone), and emits so
    /// listeners refetch `paneList`. The projection carries tmux's own active
    /// pane / zoom, which the daemon is authoritative on (multi-device
    /// convergence) — local focus travels back as a `selectPane` verb, never a
    /// write-back here. Returns the adopted session name.
    @discardableResult
    package func adoptTmuxProjection(_ entry: WorkspaceEntry) -> String {
        // Keep the pane-id allocator ahead of any id the mirror carries, so a
        // later local pane (should the store ever allocate one) can't collide
        // with a tmux %N already on screen.
        for pane in entry.panes { state.nextPane = max(state.nextPane, pane.id + 1) }

        if let idx = state.sessions.firstIndex(where: { $0.id == entry.id }) {
            let alive = Set(entry.panes.map(\.id))
            for pane in state.sessions[idx].panes where !alive.contains(pane.id) {
                if let runtime = runtimes[pane.id] {
                    runtime.shutdown()
                    runtimes.removeValue(forKey: pane.id)
                }
            }
            state.sessions[idx] = entry
            emit(.structure(session: entry.name))
        } else {
            state.sessions.append(entry)
            emit(.workspacesChanged)
            emit(.structure(session: entry.name))
        }
        return entry.name
    }
}
