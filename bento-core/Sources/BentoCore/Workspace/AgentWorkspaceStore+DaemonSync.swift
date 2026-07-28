import ACPHostKit
import ACPKit
import Foundation

// Daemon synchronization: the workspace STRUCTURE mirrors into the daemon's
// statekv — one key per session plus an index — so restarts and other
// devices converge on the same tree. See WorkspaceMirror for the wire types
// and the (rev, origin) conflict rule.

extension AgentWorkspaceStore {
    // MARK: - Daemon sync (structure follows the daemon; instances reconcile)

    /// Bring this store in line with the daemon: adopt the daemon's workspace
    /// structure when it has one (else seed it with ours), drop instance ids
    /// that no longer exist (their agents respawn with session resume), and
    /// subscribe to statechanged so edits from other devices apply live.
    /// Reuses the standing control channel; returns false when the daemon is
    /// unreachable (callers surface that as a fetch error).
    @discardableResult
    public func syncWithDaemon() async -> Bool {
        guard let persistent = launcher as? any PersistentAgentLauncher else { return false }
        do {
            let transport: AcpHostTransport
            if let existing = control {
                transport = existing
            } else {
                transport = try await persistent.makeControl()
                control = transport
                transport.onEvent = { [weak self] event in
                    guard case .stateChanged(let key) = event else { return }
                    Task { @MainActor [weak self] in
                        if key == WorkspaceMirror.indexKey {
                            await self?.pullRemoteIndex()
                        } else if let id = WorkspaceMirror.sessionID(fromKey: key) {
                            await self?.pullRemoteSession(id)
                        } else if key == Self.stateKey {
                            await self?.pullRemoteState()   // legacy whole-blob writer
                        } else if key == Self.catalogStateKey {
                            await self?.pullRemoteCatalog()
                        }
                    }
                }
            }
            if let idxData = try await transport.getState(key: WorkspaceMirror.indexKey) {
                // Per-session mirror (current schema): merge key by key —
                // local sessions with unpushed edits survive and push back.
                await applyRemoteIndex(idxData)
                mirrorToDaemon()
            } else if let data = try await transport.getState(key: Self.stateKey),
                      let decoded = Self.decodeState(data) {
                // Legacy whole-blob daemon: one-time takeover, then
                // republish per key and retire the old key.
                adopt(decoded.state)
                mirrorToDaemon()
                transport.setState(key: Self.stateKey, data: Data())
            } else {
                // Fresh daemon: seed it with ours.
                mirrorToDaemon()
            }
            await pullRemoteCatalog()
            let agents = try await transport.listAgents()
            reconcileInstances(with: agents)
            return true
        } catch {
            dlog("acp store: daemon sync failed: \(error)")
            control = nil
            return false
        }
    }

    private func pullRemoteState() async {
        guard let control else { return }
        guard let data = try? await control.getState(key: Self.stateKey),
              let decoded = Self.decodeState(data) else { return }
        adopt(decoded.state)
    }

    // MARK: - Per-session daemon mirror (push)

    /// Encode the whole state into UserDefaults (offline cache) — the
    /// remote mirror is handled separately, per session.
    private func persistLocally() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    /// Diff-push the workspace to the daemon: one statekv key per session
    /// plus an index (order + id counters). Sessions whose content didn't
    /// change since the last push aren't rewritten, so an edit to session A
    /// never touches session B's key — cross-session edits from two devices
    /// can no longer clobber each other.
    func mirrorToDaemon() {
        guard let control else { return }
        let enc = JSONEncoder()
        for session in state.sessions {
            // Only the SHARED projection travels: a focus or zoom change
            // leaves it byte-identical, so clicking around costs no write,
            // no rev, and no chance of clobbering a peer's real edit.
            let shared = WorkspaceMirror.sharedProjection(of: session)
            guard let plain = try? enc.encode(shared) else { continue }
            if mirror.pushedSessions[session.id] == plain { continue }
            let rev = (mirror.sessionRevs[session.id] ?? 0) + 1
            let envelope = WorkspaceMirror.SessionEnvelope(
                rev: rev, origin: mirror.origin, session: shared)
            guard let data = try? enc.encode(envelope) else { continue }
            control.setState(key: WorkspaceMirror.sessionKey(session.id), data: data)
            mirror.sessionRevs[session.id] = rev
            mirror.notePushed(session)
        }
        // Sessions we pushed before but no longer have were killed here:
        // delete their keys (peers see statechanged + missing data).
        let live = Set(state.sessions.map(\.id))
        for id in mirror.pushedSessions.keys where !live.contains(id) {
            control.setState(key: WorkspaceMirror.sessionKey(id), data: Data())
            mirror.pushedSessions.removeValue(forKey: id)
            mirror.sessionRevs.removeValue(forKey: id)
        }
        var index = WorkspaceMirror.WorkspaceIndex(
            rev: 0, origin: "", order: state.sessions.map(\.id),
            nextPane: state.nextPane, nextSession: state.nextSession)
        let comparator = try? enc.encode(index)
        if comparator != mirror.pushedIndex {
            mirror.indexRev += 1
            index.rev = mirror.indexRev
            index.origin = mirror.origin
            if let data = try? enc.encode(index) {
                control.setState(key: WorkspaceMirror.indexKey, data: data)
                mirror.pushedIndex = comparator
            }
        }
    }

    // MARK: - Per-session daemon mirror (pull)

    private func pullRemoteIndex() async {
        guard let control, let data = try? await control.getState(key: WorkspaceMirror.indexKey) else { return }
        await applyRemoteIndex(data)
    }

    /// Apply a remote index: adopt membership + order, pull unknown
    /// sessions, and drop local sessions the index no longer lists — unless
    /// they carry unpushed local edits, in which case they survive and the
    /// next mirror push re-publishes them (resurrection over silent loss).
    func applyRemoteIndex(_ data: Data) async {
        guard let idx = try? JSONDecoder().decode(WorkspaceMirror.WorkspaceIndex.self, from: data) else { return }
        guard WorkspaceMirror.remoteWins(remoteRev: idx.rev, remoteOrigin: idx.origin,
                                         localRev: mirror.indexRev, localOrigin: mirror.origin) else { return }
        mirror.indexRev = idx.rev
        // Counters only ever grow — max() so a stale index can't cause id reuse.
        state.nextPane = max(state.nextPane, idx.nextPane)
        state.nextSession = max(state.nextSession, idx.nextSession)

        let known = Set(state.sessions.map(\.id))
        for id in idx.order where !known.contains(id) {
            await pullRemoteSession(id)
        }
        let listed = Set(idx.order)
        var removedAny = false
        for session in state.sessions where !listed.contains(session.id) {
            if !mirror.isDirty(session) {
                removeSessionLocally(session.id)
                removedAny = true
            }
        }
        // Remote order first, then any surviving local-only sessions.
        let byID = Dictionary(uniqueKeysWithValues: state.sessions.map { ($0.id, $0) })
        var ordered = idx.order.compactMap { byID[$0] }
        ordered.append(contentsOf: state.sessions.filter { !listed.contains($0.id) })
        let orderChanged = ordered.map(\.id) != state.sessions.map(\.id)
        if orderChanged { state.sessions = ordered }
        mirror.pushedIndex = try? JSONEncoder().encode(WorkspaceMirror.WorkspaceIndex(
            rev: 0, origin: "", order: state.sessions.map(\.id),
            nextPane: state.nextPane, nextSession: state.nextSession))
        if removedAny || orderChanged {
            persistLocally()
            emit(.workspacesChanged)
        }
    }

    /// Pull one session key. Missing data = deleted remotely; otherwise
    /// adopt when the (rev, origin) pair beats what we already have.
    private func pullRemoteSession(_ id: Int) async {
        guard let control else { return }
        let data = try? await control.getState(key: WorkspaceMirror.sessionKey(id))
        guard let data else {
            handleRemoteSessionMissing(id)
            return
        }
        guard let envelope = try? JSONDecoder().decode(WorkspaceMirror.SessionEnvelope.self, from: data) else { return }
        adoptRemoteSession(id, envelope: envelope)
    }

    /// A peer deleted this session: drop it locally unless it carries
    /// unpushed local edits (those survive and re-publish on the next save).
    func handleRemoteSessionMissing(_ id: Int) {
        if let session = state.sessions.first(where: { $0.id == id }),
           !mirror.isDirty(session) {
            removeSessionLocally(id)
            persistLocally()
            emit(.workspacesChanged)
        }
    }

    /// Merge one remote session copy in, guarded by (rev, origin).
    func adoptRemoteSession(_ id: Int, envelope: WorkspaceMirror.SessionEnvelope) {
        let localRev = mirror.sessionRevs[id] ?? 0
        guard WorkspaceMirror.remoteWins(remoteRev: envelope.rev, remoteOrigin: envelope.origin,
                                         localRev: localRev, localOrigin: mirror.origin) else { return }

        var incoming = envelope.session
        incoming.id = id
        let existingIndex = state.sessions.firstIndex { $0.id == id }
        // The peer's focus is not ours. Keep what this device was looking at
        // (and repair it if the peer killed that pane).
        WorkspaceMirror.restoreViewState(
            into: &incoming,
            from: existingIndex.map { state.sessions[$0] })
        // Shut down runtimes only for THIS session's vanished panes — an
        // adopt of session A must never tear down session B's agents.
        if let existingIndex {
            let alive = Set(incoming.panes.map(\.id))
            for pane in state.sessions[existingIndex].panes where !alive.contains(pane.id) {
                if let runtime = runtimes[pane.id] {
                    runtime.shutdown()
                    runtimes.removeValue(forKey: pane.id)
                }
            }
            state.sessions[existingIndex] = incoming
        } else {
            state.sessions.append(incoming)
        }
        mirror.sessionRevs[id] = envelope.rev
        // Record what the wire holds, not what we now hold locally — else the
        // restored view state reads as an unpushed edit and bounces straight
        // back out.
        mirror.notePushed(incoming)
        persistLocally()
        if existingIndex == nil { emit(.workspacesChanged) }
        emit(.structure(session: incoming.name))
    }

    /// Drop a session and its runtimes locally (remote deletion).
    private func removeSessionLocally(_ id: Int) {
        guard let idx = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        for pane in state.sessions[idx].panes {
            if let runtime = runtimes[pane.id] {
                runtime.shutdown()
                runtimes.removeValue(forKey: pane.id)
            }
        }
        state.sessions.remove(at: idx)
        mirror.pushedSessions.removeValue(forKey: id)
        mirror.sessionRevs.removeValue(forKey: id)
    }

    /// Fetch the remote catalog and union-merge it in. When the merge holds
    /// entries the remote lacks, push back so every device converges.
    private func pullRemoteCatalog() async {
        guard let control else { return }
        guard let data = try? await control.getState(key: Self.catalogStateKey) else {
            // No remote catalog yet: seed it with ours (if any).
            if !catalog.entries.isEmpty { scheduleCatalogSave() }
            return
        }
        guard let remote = try? JSONDecoder().decode(SessionCatalog.self, from: data) else { return }
        var merged = catalog
        merged.merge(remote)
        if merged != catalog {
            catalog = merged
            persistCatalogLocally()
            emit(.historyCatalogChanged)
        }
        if merged != remote { scheduleCatalogSave() }
    }

    /// Replace the structure with a remote copy and refresh every listener.
    /// Runtimes are keyed by pane id, so live agents survive; panes that
    /// vanished get their runtimes shut down (their agents belong to whoever
    /// removed them — killing here would double-kill).
    private func adopt(_ newState: State) {
        let alive = Set(newState.sessions.flatMap { $0.panes.map(\.id) })
        for (paneID, runtime) in runtimes where !alive.contains(paneID) {
            runtime.shutdown()
            runtimes.removeValue(forKey: paneID)
        }
        state = newState
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
        emit(.workspacesChanged)
        for session in state.sessions {
            emit(.structure(session: session.name))
        }
    }

    /// Drop instance ids the daemon no longer knows (daemon restart, GC):
    /// the pane stays; its agent respawns on demand and resumes through the
    /// recorded ACP session id.
    private func reconcileInstances(with agents: [AgentInstanceInfo]) {
        let known = Set(agents.filter(\.running).map(\.id))
        for s in state.sessions.indices {
            for p in state.sessions[s].panes.indices {
                if let id = state.sessions[s].panes[p].instanceID, !known.contains(id) {
                    state.sessions[s].panes[p].instanceID = nil
                }
            }
        }
        scheduleSave()
    }

}
