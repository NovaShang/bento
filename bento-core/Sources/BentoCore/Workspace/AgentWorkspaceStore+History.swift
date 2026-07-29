import ACPHostKit
import Foundation

// The session-history catalog: metadata for every conversation ever run
// (WHO/WHERE/WHEN — never content; the conversation lives in the agent's
// own storage and comes back via session/load). Synced as its own statekv
// key so its churn never races the structure mirror.

extension AgentWorkspaceStore {
    // MARK: - Session-history catalog

    func persistCatalogLocally() {
        if let data = try? JSONEncoder().encode(catalog) {
            UserDefaults.standard.set(data, forKey: catalogPersistKey)
        }
    }

    func scheduleCatalogSave() {
        guard !catalogSaveScheduled else { return }
        catalogSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.catalogSaveScheduled = false
            self.persistCatalogLocally()
            if let data = try? JSONEncoder().encode(self.catalog) {
                self.control?.setState(key: Self.catalogStateKey, data: data)
            }
        }
    }

    /// Catalog entries, newest activity first, optionally filtered by
    /// directory (`subtree` widens the match to everything under `cwd`).
    public func catalogEntries(cwd: String? = nil, subtree: Bool = false) -> [CatalogEntry] {
        catalog.list(cwd: cwd, subtree: subtree)
    }

    /// Delete a catalog entry (history UI only; the agent-side conversation
    /// is untouched).
    public func removeCatalogEntry(_ acpSessionID: String) {
        guard catalog.remove(acpSessionID) else { return }
        scheduleCatalogSave()
        emit(.historyCatalogChanged)
    }

    /// The agent no longer has this conversation (session/load failed):
    /// grey the entry rather than hiding a truth the user remembers.
    public func markExpired(_ acpSessionID: String) {
        guard catalog.entries[acpSessionID]?.expired == false else { return }
        catalog.markExpired(acpSessionID)
        scheduleCatalogSave()
        emit(.historyCatalogChanged)
    }

    /// ACP session ids currently held by live panes (the history list's
    /// "live" badge — those rows jump to the pane instead of respawning).
    public var liveSessionIDs: Set<String> {
        Set(state.sessions.flatMap { $0.panes.compactMap(\.acpSessionID) })
    }

    /// The pane currently running an ACP session, if any.
    public func paneID(forACPSession acpSessionID: String) -> Int? {
        for sess in state.sessions {
            if let pane = sess.panes.first(where: { $0.acpSessionID == acpSessionID }) {
                return pane.id
            }
        }
        return nil
    }

    /// Insert or refresh a pane's catalog entry. `lastActive` nil keeps the
    /// existing stamp (metadata-only refresh).
    func catalogUpsert(pane: PaneEntry, lastActive: Date? = nil) {
        guard let sid = pane.acpSessionID, !sid.isEmpty else { return }
        catalog.upsert(
            acpSessionID: sid,
            title: catalogTitle(for: pane),
            presetID: pane.presetID,
            cwd: pane.cwd,
            lastActive: lastActive)
        scheduleCatalogSave()
        emit(.historyCatalogChanged)
    }

    /// A history row's display title: user rename → agent-side session name
    /// → first prompt (truncated) → runtime title → cwd tail.
    private func catalogTitle(for pane: PaneEntry) -> String {
        if let title = pane.title, !title.isEmpty { return title }
        if let runtime = runtimes[pane.id] {
            if let session = runtime.sessionTitle, !session.isEmpty { return session }
            if let preview = runtime.firstUserPromptPreview {
                return String(preview.prefix(64))
            }
            if !runtime.title.isEmpty { return runtime.title }
        }
        return (pane.cwd as NSString).lastPathComponent
    }

    /// Turn-lifecycle hook: refresh lastActive when a turn has finished
    /// (throttled to 1s — onActivityChange fires on every state flip).
    func catalogNoteActivity(paneID: Int) {
        guard let entry = paneEntry(paneID),
              let sid = entry.acpSessionID,
              let runtime = runtimes[paneID],
              runtime.hasCompletedTurn else { return }
        if let existing = catalog.entries[sid],
           Date().timeIntervalSince(existing.lastActive) < 1.0 { return }
        catalogUpsert(pane: entry, lastActive: Date())
    }

    /// A closing pane GRADUATES into the catalog: the agent process dies but
    /// the conversation lives on agent-side, reachable via respawn + load.
    func catalogGraduate(pane: PaneEntry) {
        catalogUpsert(pane: pane)
    }

    /// Open a history entry: a new pane in `name` (largest-cell insertion)
    /// pre-filled with the recorded preset/cwd/ACP session id, so spawn takes
    /// the existing respawn + session/load path. A session already live in a
    /// pane is focused instead (two panes must not drive one ACP session).
    /// Returns the pane id showing the conversation.
    @discardableResult
    public func openHistorySession(_ entry: CatalogEntry, inSession name: String) -> Int? {
        if let live = paneID(forACPSession: entry.acpSessionID) {
            selectPane(live)
            return live
        }
        guard let sess = workspace(name) else { return nil }
        let newID = allocPane()
        let inserted = LayoutTree.inserting(pane: newID, into: sess.layout)
        guard LayoutTree.leafOrder(of: inserted).contains(newID) else { return nil }
        let (preset, startCommand) = Self.presetForCatalogID(entry.presetID)
        withWorkspace(name) { sess in
            sess.panes.append(PaneEntry(
                id: newID, presetID: preset.id,
                customPreset: preset.isBuiltin ? nil : preset,
                cwd: entry.cwd, title: nil, instanceID: nil,
                acpSessionID: entry.acpSessionID, startCommand: startCommand))
            sess.layout = inserted
            sess.activePane = newID
            sess.zoomedPane = nil
        }
        spawn(paneID: newID)
        emit(.structure(session: name))
        return newID
    }

    /// Open a history entry IN an existing pane (reuse it) instead of splitting
    /// a new one: the pane's current conversation graduates to history, then the
    /// pane is reconfigured with the entry's preset/cwd/ACP session id and
    /// respawned — spawn takes the reattach + session/load resume path from the
    /// recorded ids. A session already live in ANOTHER pane is focused instead
    /// (two panes must not drive one ACP session). Returns the pane showing it.
    @discardableResult
    public func openHistorySession(_ entry: CatalogEntry, inPane paneID: Int) -> Int? {
        if let live = self.paneID(forACPSession: entry.acpSessionID) {
            selectPane(live)
            return live
        }
        guard let name = workspaceName(ofPane: paneID) else { return nil }
        // The outgoing conversation stays resumable from history.
        if let current = paneEntry(paneID) {
            catalogGraduate(pane: current)
        }
        teardownRuntime(paneID, killAgent: true)
        let (preset, startCommand) = Self.presetForCatalogID(entry.presetID)
        withWorkspace(name) { sess in
            guard let p = sess.panes.firstIndex(where: { $0.id == paneID }) else { return }
            sess.panes[p].presetID = preset.id
            sess.panes[p].customPreset = preset.isBuiltin ? nil : preset
            sess.panes[p].cwd = entry.cwd
            sess.panes[p].title = nil
            sess.panes[p].instanceID = nil
            sess.panes[p].acpSessionID = entry.acpSessionID
            sess.panes[p].startCommand = startCommand
            sess.activePane = paneID
        }
        emit(.activity(pane: paneID))
        spawn(paneID: paneID)
        emit(.structure(session: name))
        return paneID
    }

    /// Open a history entry choosing the target session automatically: the
    /// session already holding it live, else `preferredSession` (the caller's
    /// attached session), else the most recently active session, else a
    /// fresh default one at the entry's directory. Returns where it landed.
    @discardableResult
    public func openHistorySession(
        _ entry: CatalogEntry, preferredSession: String? = nil
    ) -> (session: String, pane: Int)? {
        if let live = paneID(forACPSession: entry.acpSessionID),
           let name = workspaceName(ofPane: live) {
            selectPane(live)
            return (name, live)
        }
        let target: String
        if let preferredSession, workspace(preferredSession) != nil {
            target = preferredSession
        } else if let recent = state.sessions.max(by: { $0.lastActivity < $1.lastActivity }) {
            target = recent.name
        } else {
            target = ensureWorkspace("bento", cwd: entry.cwd)
        }
        guard let pane = openHistorySession(entry, inSession: target) else { return nil }
        return (target, pane)
    }

    /// Resolve a catalog entry's preset id back to a runnable preset.
    /// Custom presets persist as "custom:<command>", so the command text
    /// round-trips through the id.
    static func presetForCatalogID(_ presetID: String) -> (ACPAgentPreset, String?) {
        if presetID.hasPrefix("custom:") {
            let command = String(presetID.dropFirst("custom:".count))
            return (preset(forCommand: command), command)
        }
        if let builtin = ACPAgentPreset.builtin.first(where: { $0.id == presetID }) {
            return (builtin, nil)
        }
        return (defaultPreset, nil)
    }

    func presetFor(_ entry: PaneEntry) -> ACPAgentPreset {
        var preset: ACPAgentPreset
        if let custom = entry.customPreset {
            // Legacy records can carry terminal-era TUI commands ("claude");
            // route them through the alias table so the pane speaks ACP.
            if let aliasID = Self.commandAliases[custom.command],
               let builtin = ACPAgentPreset.builtin.first(where: { $0.id == aliasID }) {
                // Preserve any per-pane env the custom record carried — a
                // forward-looking custom preset may set env vars on top
                // of an otherwise-builtin agent. Builtin defaults stay
                // (command/args/etc.), env is merged in.
                preset = builtin
                for (k, v) in custom.env { preset.env[k] = v }
            } else {
                preset = custom
            }
        } else {
            preset = ACPAgentPreset.builtin.first { $0.id == entry.presetID } ?? Self.defaultPreset
        }
        // Claude Code provider switching: merge the active provider's env
        // (ANTHROPIC_BASE_URL / AUTH_TOKEN / model aliases) into the
        // preset. Any key the pane already sets wins — provider values
        // only fill in slots the preset leaves empty.
        if preset.id == "claude-code" {
            let store = providerStore ?? ClaudeCodeProviderStore.shared
            if let provider = store.active, !provider.isEmpty {
                for (k, v) in provider.env where preset.env[k] == nil {
                    preset.env[k] = v
                }
            }
        }
        return preset
    }

    func paneTitle(_ entry: PaneEntry) -> String {
        if let title = entry.title, !title.isEmpty { return title }
        if let runtime = runtimes[entry.id] {
            if let session = runtime.sessionTitle, !session.isEmpty { return session }
            if !runtime.title.isEmpty { return runtime.title }
        }
        return (entry.cwd as NSString).lastPathComponent
    }

}
