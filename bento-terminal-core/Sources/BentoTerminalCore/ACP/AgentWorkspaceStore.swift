import ACPKit
import ACPHostKit
import Foundation

/// What a pane holds. Only `.acp` is user-creatable today; the other kinds
/// are reserved seats in the model (docs/hybrid-workbench-design.md):
/// `.terminal` = daemon-hosted pty, `.file` = preview, `.browser` = web.
public enum PaneKind: String, Codable, Sendable {
    case acp, terminal, file, browser
}

/// The workspace's source of truth: one process-wide store owning the
/// session ⊃ pane structure, each session's layout tree, and each pane's
/// live agent runtime (AgentSessionViewModel).
///
/// Persistence: the STRUCTURE persists here (UserDefaults locally, mirrored
/// into the daemon's statekv for restarts and multi-device). The AGENT
/// PROCESSES persist in the daemon (acphost instance registry) — pane
/// records carry the instance id so a restart reattaches instead of
/// respawning.
@MainActor
public final class AgentWorkspaceStore {
    public static let shared = AgentWorkspaceStore()

    /// Mutation fan-out for attached view models / bridges.
    public enum Event {
        /// Panes appeared, disappeared or moved — full refresh.
        case structure(session: String)
        /// Pure geometry change (divider drag, canvas resize).
        case geometry(session: String, layout: LayoutTree.Node)
        /// A pane's turn-lifecycle state changed (working/awaiting/idle).
        case activity(pane: Int)
        /// The session list itself changed (created/killed/renamed).
        case sessionsChanged
        /// The history catalog changed (upsert/merge/remove) — history UI refresh.
        case historyCatalogChanged
    }
    /// Multiple listeners (one per app window); keyed by ObjectIdentifier.
    private var listeners: [ObjectIdentifier: (Event) -> Void] = [:]

    public func addListener(_ owner: AnyObject, _ handler: @escaping (Event) -> Void) {
        listeners[ObjectIdentifier(owner)] = handler
    }

    public func removeListener(_ owner: AnyObject) {
        listeners.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func emit(_ event: Event) {
        for handler in listeners.values { handler(event) }
    }

    // MARK: - Records

    struct PaneEntry: Codable {
        var id: Int
        var kind: PaneKind = .acp
        var presetID: String
        var customPreset: ACPAgentPreset?
        var cwd: String
        /// User-set title (rename); nil = live default (runtime title / cwd).
        var title: String?
        /// Daemon instance id (persistent agents); nil until spawned or for
        /// in-process fallback agents.
        var instanceID: String?
        var acpSessionID: String?
        /// What "Duplicate Current" re-runs (the original command text).
        var startCommand: String?

        private enum CodingKeys: String, CodingKey {
            case id, kind, presetID, customPreset, cwd, title, instanceID,
                 acpSessionID, startCommand
        }

        init(id: Int, kind: PaneKind = .acp, presetID: String,
             customPreset: ACPAgentPreset?, cwd: String, title: String?,
             instanceID: String?, acpSessionID: String?, startCommand: String?) {
            self.id = id
            self.kind = kind
            self.presetID = presetID
            self.customPreset = customPreset
            self.cwd = cwd
            self.title = title
            self.instanceID = instanceID
            self.acpSessionID = acpSessionID
            self.startCommand = startCommand
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            kind = try c.decodeIfPresent(PaneKind.self, forKey: .kind) ?? .acp
            presetID = try c.decode(String.self, forKey: .presetID)
            customPreset = try c.decodeIfPresent(ACPAgentPreset.self, forKey: .customPreset)
            cwd = try c.decode(String.self, forKey: .cwd)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            instanceID = try c.decodeIfPresent(String.self, forKey: .instanceID)
            acpSessionID = try c.decodeIfPresent(String.self, forKey: .acpSessionID)
            startCommand = try c.decodeIfPresent(String.self, forKey: .startCommand)
        }
    }

    struct SessionEntry: Codable {
        var id: Int
        var name: String
        var panes: [PaneEntry]
        var layout: LayoutTree.Node
        var activePane: Int
        /// Temporarily maximized pane (zoom); nil = normal tiling.
        var zoomedPane: Int?
        var cols: Int
        var rows: Int
        /// Last mutation / agent activity — the menubar session list's
        /// relative-time column.
        var lastActivity: Date = Date()

        private enum CodingKeys: String, CodingKey {
            case id, name, panes, layout, activePane, zoomedPane, cols, rows, lastActivity
        }

        init(id: Int, name: String, panes: [PaneEntry], layout: LayoutTree.Node,
             activePane: Int, zoomedPane: Int? = nil, cols: Int, rows: Int) {
            self.id = id
            self.name = name
            self.panes = panes
            self.layout = layout
            self.activePane = activePane
            self.zoomedPane = zoomedPane
            self.cols = cols
            self.rows = rows
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            panes = try c.decode([PaneEntry].self, forKey: .panes)
            layout = try c.decode(LayoutTree.Node.self, forKey: .layout)
            activePane = try c.decode(Int.self, forKey: .activePane)
            zoomedPane = try c.decodeIfPresent(Int.self, forKey: .zoomedPane)
            cols = try c.decode(Int.self, forKey: .cols)
            rows = try c.decode(Int.self, forKey: .rows)
            lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity) ?? Date()
        }
    }

    struct State: Codable {
        /// Bumped when the persisted shape changes; v1 was the window-era
        /// structure, migrated on load.
        var schema: Int = 2
        var sessions: [SessionEntry] = []
        var nextPane = 1
        var nextSession = 1

        private enum CodingKeys: String, CodingKey {
            case schema, sessions, nextPane, nextSession
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
            sessions = try c.decode([SessionEntry].self, forKey: .sessions)
            nextPane = try c.decode(Int.self, forKey: .nextPane)
            nextSession = try c.decode(Int.self, forKey: .nextSession)
        }
    }

    // MARK: - Legacy (window-era) persistence migration

    private struct LegacyPaneEntry: Codable {
        var id: Int
        var windowID: Int
        var presetID: String
        var customPreset: ACPAgentPreset?
        var cwd: String
        var title: String?
        var instanceID: String?
        var acpSessionID: String?
        var startCommand: String?
    }

    private struct LegacyWindowEntry: Codable {
        var id: Int
        var name: String
        var layout: String
        var activePane: Int
        var zoomed: Bool
    }

    private struct LegacySessionEntry: Codable {
        var id: Int
        var name: String
        var windows: [LegacyWindowEntry]
        var panes: [LegacyPaneEntry]
        var activeWindow: Int
        var options: [String: String]
        var cols: Int
        var rows: Int
        var lastActivity: Date?
    }

    private struct LegacyState: Codable {
        var sessions: [LegacySessionEntry] = []
        var nextPane = 1
        var nextWindow = 1
        var nextSession = 1
    }

    /// Decode a persisted blob at either schema; legacy window-era states are
    /// flattened (every window's panes join the session; the layout is
    /// rebuilt as a tiled grid — a lossy but honest one-time migration).
    static func decodeState(_ data: Data) -> (state: State, migrated: Bool)? {
        if let v2 = try? JSONDecoder().decode(State.self, from: data), v2.schema >= 2 {
            return (v2, false)
        }
        guard let legacy = try? JSONDecoder().decode(LegacyState.self, from: data) else {
            return nil
        }
        var state = State()
        state.nextPane = legacy.nextPane
        state.nextSession = legacy.nextSession
        for old in legacy.sessions {
            // Window order, then pane-array order within each window.
            var ordered: [LegacyPaneEntry] = []
            for window in old.windows {
                ordered.append(contentsOf: old.panes.filter { $0.windowID == window.id })
            }
            ordered.append(contentsOf: old.panes.filter { p in
                !ordered.contains { $0.id == p.id }
            })
            guard !ordered.isEmpty,
                  let layout = LayoutTree.tiledPreset(
                      panes: ordered.map(\.id), cols: old.cols, rows: old.rows)
            else { continue }
            let activePane = old.windows.first { $0.id == old.activeWindow }
                .map(\.activePane)
                .flatMap { active in ordered.contains { $0.id == active } ? active : nil }
                ?? ordered[0].id
            state.sessions.append(SessionEntry(
                id: old.id, name: old.name,
                panes: ordered.map { p in
                    PaneEntry(id: p.id, kind: .acp, presetID: p.presetID,
                              customPreset: p.customPreset, cwd: p.cwd, title: p.title,
                              instanceID: p.instanceID, acpSessionID: p.acpSessionID,
                              startCommand: p.startCommand)
                },
                layout: layout, activePane: activePane,
                cols: old.cols, rows: old.rows))
        }
        return (state, true)
    }

    static let defaultCols = 160
    static let defaultRows = 48
    /// Local persistence key. The Mac's shared store keeps the historical
    /// key; iOS keeps one store PER PAIRED DAEMON (a phone talks to several
    /// Macs), each under its own key.
    private let persistKey: String
    private static let defaultAgentKey = "acp_default_agent"

    /// One store per paired daemon (iOS). The daemon's statekv is the truth;
    /// the local key is just the offline cache.
    private static var perDaemon: [String: AgentWorkspaceStore] = [:]
    public static func store(forDaemon daemonID: String) -> AgentWorkspaceStore {
        if let existing = perDaemon[daemonID] { return existing }
        let store = AgentWorkspaceStore(persistKey: "acp_workspace_\(daemonID)")
        perDaemon[daemonID] = store
        return store
    }

    /// The per-daemon store with its relay launcher wired (idempotent).
    /// Shared by the bridge (session attach) and the session-picker lister,
    /// so whichever runs first establishes the daemon link.
    public static func relayStore(
        daemonID: String, deviceID: String, hostKeyFingerprint: String,
        devicePrivateKey: Data, relayBaseURL: String
    ) -> AgentWorkspaceStore {
        let store = store(forDaemon: daemonID)
        if store.launcher == nil {
            let config = AcpRelayConfig(
                relayBaseURL: relayBaseURL,
                daemonID: daemonID,
                deviceID: deviceID,
                devicePrivateKey: devicePrivateKey,
                hostKeyFingerprint: hostKeyFingerprint)
            store.launcher = RemoteAgentLauncher(config: config)
            Task { await store.syncWithDaemon() }
        }
        return store
    }

    private(set) var state = State()
    /// Live agent runtimes keyed by pane id. Process-wide: two windows
    /// attached to the same session share them.
    private(set) var runtimes: [Int: AgentSessionViewModel] = [:]
    /// Injected at app start (mac: adaptive daemon/in-process; iOS: relay).
    public var launcher: (any AgentLauncher)?
    /// Per-pane Claude Code provider overrides. Defaults to nil, meaning
    /// `ClaudeCodeProviderStore.shared` is used. Injected by tests so each
    /// test gets a fresh store instead of mutating the process singleton.
    public var providerStore: ClaudeCodeProviderStore?

    private var saveScheduled = false
    /// Long-lived control channel to the daemon (statekv + instance list).
    private var control: AcpHostTransport?
    /// Legacy whole-blob key; current daemons hold per-session keys instead
    /// (WorkspaceMirror.indexKey / sessionKey). Read once for migration.
    private static let stateKey = "workspace"
    /// Bookkeeping for the per-session daemon mirror (see WorkspaceMirror).
    /// Internal (not private) so merge-semantics tests can seed the caches.
    let mirror = WorkspaceMirrorState()

    /// The session-history catalog (metadata only; conversations stay in
    /// the agents' own storage). Separate statekv key so its churn never
    /// races the workspace-structure blob.
    private(set) var catalog = SessionCatalog()
    private let catalogPersistKey: String
    private var catalogSaveScheduled = false
    private static let catalogStateKey = "history-catalog"

    /// The catalog's local cache key, derived from the workspace key so the
    /// per-daemon stores (iOS) each keep their own catalog.
    static func catalogKey(forWorkspaceKey key: String) -> String {
        if key == "acp_workspace_v1" { return "acp_history_catalog" }
        if key.hasPrefix("acp_workspace_") {
            return "acp_history_catalog_" + key.dropFirst("acp_workspace_".count)
        }
        return "acp_history_catalog_" + key
    }

    public init(persistKey: String = "acp_workspace_v1") {
        self.persistKey = persistKey
        self.catalogPersistKey = Self.catalogKey(forWorkspaceKey: persistKey)
        load()
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: catalogPersistKey),
           let decoded = try? JSONDecoder().decode(SessionCatalog.self, from: data) {
            catalog = decoded
        }
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let decoded = Self.decodeState(data) else { return }
        state = decoded.state
        if decoded.migrated { scheduleSave() }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let data = try? JSONEncoder().encode(self.state) {
                UserDefaults.standard.set(data, forKey: self.persistKey)
            }
            // Structure lives with the daemon: mirror every save so restarts
            // and other devices read the same tree — one statekv key per
            // session (+ index), so devices editing DIFFERENT sessions can
            // no longer clobber each other's whole tree (per-key LWW with a
            // rev guard, not whole-blob LWW).
            self.mirrorToDaemon()
        }
    }

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
    private func mirrorToDaemon() {
        guard let control else { return }
        let enc = JSONEncoder()
        for session in state.sessions {
            guard let plain = try? enc.encode(session) else { continue }
            if mirror.pushedSessions[session.id] == plain { continue }
            let rev = (mirror.sessionRevs[session.id] ?? 0) + 1
            let envelope = WorkspaceMirror.SessionEnvelope(
                rev: rev, origin: mirror.origin, session: session)
            guard let data = try? enc.encode(envelope) else { continue }
            control.setState(key: WorkspaceMirror.sessionKey(session.id), data: data)
            mirror.sessionRevs[session.id] = rev
            mirror.pushedSessions[session.id] = plain
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
            emit(.sessionsChanged)
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
            emit(.sessionsChanged)
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
        mirror.pushedSessions[id] = try? JSONEncoder().encode(incoming)
        persistLocally()
        if existingIndex == nil { emit(.sessionsChanged) }
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
        emit(.sessionsChanged)
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

    // MARK: - Lookup helpers

    func sessionIndex(_ name: String) -> Int? {
        state.sessions.firstIndex { $0.name == name }
    }

    func session(_ name: String) -> SessionEntry? {
        state.sessions.first { $0.name == name }
    }

    /// Session containing a pane (pane ids are globally unique).
    func sessionName(ofPane paneID: Int) -> String? {
        state.sessions.first { $0.panes.contains { $0.id == paneID } }?.name
    }

    public func runtime(forPane paneID: Int) -> AgentSessionViewModel? {
        runtimes[paneID]
    }

    func paneEntry(_ paneID: Int) -> PaneEntry? {
        for session in state.sessions {
            if let pane = session.panes.first(where: { $0.id == paneID }) { return pane }
        }
        return nil
    }

    public var sessionList: [(id: Int, name: String)] {
        state.sessions.map { ($0.id, $0.name) }
    }

    // MARK: - Direct read accessors (the view model's data source)

    /// The session's panes in layout (leaf) order, with cell geometry from
    /// the layout tree — what the view model publishes as `sessionPanes`.
    public func paneList(session name: String) -> [Pane] {
        guard let sess = session(name) else { return [] }
        let frames = LayoutTree.frames(of: sess.layout)
        return LayoutTree.leafOrder(of: sess.layout).compactMap { paneID in
            guard let entry = sess.panes.first(where: { $0.id == paneID }),
                  let frame = frames[paneID] else { return nil }
            return Pane(
                id: PaneID(paneID),
                width: frame.w, height: frame.h, x: frame.x, y: frame.y,
                isActive: sess.activePane == paneID,
                isZoomed: sess.zoomedPane == paneID,
                currentCommand: presetFor(entry).command,
                title: paneTitle(entry))
        }
    }

    /// A pane's working directory (the directory its agent was started in).
    public func paneCwd(_ paneID: Int) -> String? {
        paneEntry(paneID)?.cwd
    }

    /// The original command a pane was created with (what "Duplicate
    /// Current" re-runs); nil for default-agent panes.
    public func paneStartCommand(_ paneID: Int) -> String? {
        paneEntry(paneID)?.startCommand
    }

    /// The command the pane's resolved preset actually runs.
    public func paneCurrentCommand(_ paneID: Int) -> String? {
        paneEntry(paneID).map { presetFor($0).command }
    }

    // MARK: - Wizard

    /// The Agent-wizard flow: build the whole session per spec BEFORE the
    /// view model attaches. Layout presets beyond one pane land as the
    /// tiled grid.
    public func createAgentSession(_ spec: AgentSpec) {
        guard session(spec.sessionName) == nil else { return }
        let command = spec.agentCommand.isEmpty ? nil : spec.agentCommand
        createSession(spec.sessionName, cwd: spec.workingDir,
                      preset: Self.preset(forCommand: command))
        let paneCount = max(spec.layout.paneCount, 1)
        if paneCount > 1 {
            for _ in 1..<paneCount {
                _ = newPane(session: spec.sessionName,
                            cwd: spec.workingDir, command: command)
            }
            applyTiled(session: spec.sessionName)
        }
    }

    // MARK: - App-level overview (the menubar's session menu source)

    public struct SessionOverview {
        /// One row per pane.
        public struct PaneRow {
            public let index: Int
            public let name: String
            public let active: Bool
            public let paneCount: Int
        }
        public let name: String
        public let lastActivity: Date
        public let panes: [PaneRow]
    }

    public var overview: [SessionOverview] {
        state.sessions.map { sess in
            let order = LayoutTree.leafOrder(of: sess.layout)
            let rows = order.enumerated().compactMap { index, paneID -> SessionOverview.PaneRow? in
                guard let entry = sess.panes.first(where: { $0.id == paneID }) else { return nil }
                return SessionOverview.PaneRow(
                    index: index, name: paneTitle(entry),
                    active: sess.activePane == paneID, paneCount: 1)
            }
            return SessionOverview(name: sess.name, lastActivity: sess.lastActivity,
                                   panes: rows)
        }
    }

    /// Select a pane by its position in the session (menubar submenu rows).
    public func selectPane(session name: String, index: Int) {
        guard let sess = session(name) else { return }
        let order = LayoutTree.leafOrder(of: sess.layout)
        guard order.indices.contains(index) else { return }
        selectPane(order[index])
    }

    // MARK: - Presets

    /// The agent a bare seed (no command) runs: the user's chosen default.
    public static var defaultPreset: ACPAgentPreset {
        let id = UserDefaults.standard.string(forKey: defaultAgentKey) ?? "opencode"
        return ACPAgentPreset.builtin.first { $0.id == id } ?? ACPAgentPreset.builtin[0]
    }

    /// Legacy/TUI command names (the wizard's presets, `pane_current_command`
    /// style values) → the ACP builtin that actually speaks the protocol.
    /// `claude` the TUI is NOT an ACP agent; `claude-agent-acp` is.
    static let commandAliases: [String: String] = [
        "claude": "claude-code", "claude-agent-acp": "claude-code",
        "codex": "codex", "codex-acp": "codex",
        "gemini": "gemini",
        "opencode": "opencode",
        "cursor-agent": "cursor",
        "copilot": "copilot",
        "amp": "amp", "amp-acp": "amp",
        "qwen": "qwen-code",
        "goose": "goose",
        "kimi": "kimi",
    ]

    /// Map a seed command string to a preset: a known agent (by ACP binary or
    /// legacy TUI name), anything else a custom preset running the command.
    static func preset(forCommand command: String?) -> ACPAgentPreset {
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return defaultPreset
        }
        let tokens = command.split(separator: " ").map(String.init)
        if let bin = tokens.first, let aliasID = commandAliases[bin],
           let builtin = ACPAgentPreset.builtin.first(where: { $0.id == aliasID }) {
            return builtin
        }
        if let bin = tokens.first {
            if let builtin = ACPAgentPreset.builtin.first(where: {
                $0.command == bin && Array($0.args.prefix(tokens.count - 1)) == Array(tokens.dropFirst())
            }) {
                return builtin
            }
            if let builtin = ACPAgentPreset.builtin.first(where: { $0.command == bin }),
               tokens.count == 1 {
                return builtin
            }
        }
        return ACPAgentPreset(
            id: "custom:\(command)",
            name: command,
            command: tokens.first ?? command,
            args: Array(tokens.dropFirst()),
            detail: "Custom command",
            installHint: nil)
    }

    // MARK: - Session lifecycle

    /// Attach-or-create: returns the session, creating it with one
    /// default-agent pane when missing.
    @discardableResult
    public func ensureSession(_ name: String, cwd: String? = nil,
                              preset: ACPAgentPreset? = nil) -> String {
        if session(name) != nil { return name }
        createSession(name, cwd: cwd, preset: preset)
        return name
    }

    /// A fresh session with one pane.
    public func createSession(_ name: String, cwd: String? = nil,
                              preset: ACPAgentPreset? = nil) {
        guard session(name) == nil else { return }
        let paneID = allocPane()
        let sessionID = state.nextSession
        state.nextSession += 1
        let useCwd = cwd ?? NSHomeDirectory()
        let usePreset = preset ?? Self.defaultPreset
        let pane = PaneEntry(
            id: paneID, presetID: usePreset.id,
            customPreset: usePreset.isBuiltin ? nil : usePreset,
            cwd: useCwd, title: nil, instanceID: nil, acpSessionID: nil,
            startCommand: nil)
        state.sessions.append(SessionEntry(
            id: sessionID, name: name, panes: [pane],
            layout: LayoutTree.single(pane: paneID, w: Self.defaultCols, h: Self.defaultRows),
            activePane: paneID,
            cols: Self.defaultCols, rows: Self.defaultRows))
        spawn(paneID: paneID)
        scheduleSave()
        emit(.sessionsChanged)
        emit(.structure(session: name))
    }

    public func killSession(_ name: String) {
        guard let idx = sessionIndex(name) else { return }
        for pane in state.sessions[idx].panes {
            // Graduate before teardown: the runtime's transcript still feeds
            // the catalog title.
            catalogGraduate(pane: pane)
            teardownRuntime(pane.id, killAgent: true)
        }
        state.sessions.remove(at: idx)
        scheduleSave()
        emit(.sessionsChanged)
    }

    public func renameSession(_ name: String, to newName: String) {
        guard let idx = sessionIndex(name), session(newName) == nil else { return }
        state.sessions[idx].name = newName
        scheduleSave()
        emit(.sessionsChanged)
    }

    // MARK: - Pane ops

    private func allocPane() -> Int {
        defer { state.nextPane += 1 }
        return state.nextPane
    }

    private func withSession(_ name: String, _ body: (inout SessionEntry) -> Void) {
        guard let idx = sessionIndex(name) else { return }
        body(&state.sessions[idx])
        state.sessions[idx].lastActivity = Date()
        scheduleSave()
    }

    /// Split `target`'s cell; the new pane runs `preset` in `cwd` and becomes
    /// the session's active pane. Returns the new pane id.
    @discardableResult
    public func splitPane(session name: String, target: Int, horizontal: Bool,
                          cwd: String?, command: String?) -> Int? {
        guard let sess = session(name),
              let entry = sess.panes.first(where: { $0.id == target }) else { return nil }
        let newID = allocPane()
        guard let split = LayoutTree.splitting(
            pane: target, adding: newID, horizontal: horizontal, in: sess.layout) else { return nil }
        let preset = Self.preset(forCommand: command)
        let useCwd = cwd ?? entry.cwd
        withSession(name) { sess in
            sess.panes.append(PaneEntry(
                id: newID, presetID: preset.id,
                customPreset: preset.isBuiltin ? nil : preset,
                cwd: useCwd, title: nil, instanceID: nil, acpSessionID: nil,
                startCommand: command))
            sess.layout = split
            sess.activePane = newID
            sess.zoomedPane = nil
        }
        spawn(paneID: newID)
        emit(.structure(session: name))
        return newID
    }

    /// A fresh pane with no explicit target: split the largest cell (the
    /// balanced insertion). Returns the new pane id.
    @discardableResult
    public func newPane(session name: String, cwd: String?, command: String?) -> Int? {
        guard let sess = session(name) else { return nil }
        let newID = allocPane()
        let inserted = LayoutTree.inserting(pane: newID, into: sess.layout)
        guard LayoutTree.leafOrder(of: inserted).contains(newID) else { return nil }
        let preset = Self.preset(forCommand: command)
        withSession(name) { sess in
            sess.panes.append(PaneEntry(
                id: newID, presetID: preset.id,
                customPreset: preset.isBuiltin ? nil : preset,
                cwd: cwd ?? NSHomeDirectory(), title: nil, instanceID: nil,
                acpSessionID: nil, startCommand: command))
            sess.layout = inserted
            sess.activePane = newID
            sess.zoomedPane = nil
        }
        spawn(paneID: newID)
        emit(.structure(session: name))
        return newID
    }

    /// Kill the agent, collapse the cell; the session ends with its last pane.
    public func killPane(_ paneID: Int) {
        guard let name = sessionName(ofPane: paneID),
              let sess = session(name) else { return }
        if sess.panes.count <= 1 {
            killSession(name)
            return
        }
        if let entry = sess.panes.first(where: { $0.id == paneID }) {
            catalogGraduate(pane: entry)
        }
        teardownRuntime(paneID, killAgent: true)
        withSession(name) { sess in
            sess.panes.removeAll { $0.id == paneID }
            if let pruned = LayoutTree.removing(pane: paneID, from: sess.layout) {
                sess.layout = pruned
                if sess.activePane == paneID {
                    sess.activePane = LayoutTree.leafOrder(of: pruned).first ?? 0
                }
            }
            if sess.zoomedPane == paneID { sess.zoomedPane = nil }
        }
        emit(.structure(session: name))
    }

    public func selectPane(_ paneID: Int) {
        guard let name = sessionName(ofPane: paneID) else { return }
        withSession(name) { sess in
            sess.activePane = paneID
            // Selecting a pane hidden behind a zoom unzooms (tmux behavior).
            if let zoomed = sess.zoomedPane, zoomed != paneID {
                sess.zoomedPane = nil
            }
        }
        emit(.structure(session: name))
    }

    /// Replace a pane's conversation with a fresh one (same preset/cwd, new
    /// ACP session). The outgoing conversation graduates to the catalog so
    /// the user can still resume it from history; the pane itself stays in
    /// place (no layout change).
    @discardableResult
    public func resetPane(_ paneID: Int) -> Bool {
        guard let name = sessionName(ofPane: paneID) else { return false }
        if let entry = paneEntry(paneID) {
            catalogGraduate(pane: entry)
        }
        teardownRuntime(paneID, killAgent: true)
        // Clear the recorded ids so the next spawn doesn't resume the old
        // conversation — spawn reads these to decide resume vs. fresh.
        withSession(name) { sess in
            guard let p = sess.panes.firstIndex(where: { $0.id == paneID }) else { return }
            sess.panes[p].acpSessionID = nil
            sess.panes[p].instanceID = nil
            sess.panes[p].title = nil
        }
        emit(.activity(pane: paneID))
        spawn(paneID: paneID)
        emit(.structure(session: name))
        return true
    }

    public func renamePane(_ paneID: Int, to title: String) {
        guard let name = sessionName(ofPane: paneID) else { return }
        withSession(name) { sess in
            guard let p = sess.panes.firstIndex(where: { $0.id == paneID }) else { return }
            sess.panes[p].title = title
        }
        runtimes[paneID]?.title = title
        if let entry = paneEntry(paneID) { catalogUpsert(pane: entry) }
        emit(.structure(session: name))
    }

    /// Zoom toggle: temporarily maximize one pane over the tiling.
    public func toggleZoom(_ paneID: Int) {
        guard let name = sessionName(ofPane: paneID) else { return }
        withSession(name) { sess in
            if sess.zoomedPane == paneID {
                sess.zoomedPane = nil
            } else {
                sess.zoomedPane = paneID
                sess.activePane = paneID
            }
        }
        emit(.structure(session: name))
    }

    /// Trade positions with the previous/next pane in layout order.
    public func swapPane(_ paneID: Int, up: Bool) {
        guard let name = sessionName(ofPane: paneID),
              let sess = session(name),
              let other = LayoutTree.neighbor(of: paneID, previous: up, in: sess.layout)
        else { return }
        swapPanes(paneID, other)
    }

    /// Positions trade; content follows ids.
    public func swapPanes(_ a: Int, _ b: Int) {
        guard a != b,
              let name = sessionName(ofPane: a),
              sessionName(ofPane: b) == name,
              let sess = session(name) else { return }
        let swapped = LayoutTree.swapping(a, b, in: sess.layout)
        withSession(name) { sess in
            sess.layout = swapped
        }
        emitGeometry(session: name)
    }

    /// Dock `source` against `target`'s edge (the VS Code edge-dock drop).
    public func dockPane(_ source: Int, at target: Int, horizontal: Bool, before: Bool) {
        guard let name = sessionName(ofPane: source),
              sessionName(ofPane: target) == name,
              let sess = session(name),
              let docked = LayoutTree.docking(
                  pane: source, at: target, horizontal: horizontal, before: before,
                  in: sess.layout)
        else { return }
        withSession(name) { sess in
            sess.layout = docked
            sess.activePane = source
        }
        emit(.structure(session: name))
    }

    /// Move a pane into another session (splits that session's active cell).
    /// The source session ends when this was its last pane.
    @discardableResult
    public func movePane(_ paneID: Int, toSession destName: String) -> Bool {
        guard let sourceName = sessionName(ofPane: paneID),
              sourceName != destName,
              let destSess = session(destName) else { return false }
        var entry: PaneEntry?
        if let sourceSess = session(sourceName), sourceSess.panes.count <= 1 {
            // Last pane: lift the entry out, then drop the empty session
            // WITHOUT killing the agent (it's moving, not dying).
            withSession(sourceName) { sess in
                entry = sess.panes.first
                sess.panes.removeAll()
            }
            if let idx = sessionIndex(sourceName) {
                state.sessions.remove(at: idx)
            }
            emit(.sessionsChanged)
        } else {
            withSession(sourceName) { sess in
                guard let p = sess.panes.firstIndex(where: { $0.id == paneID }) else { return }
                entry = sess.panes.remove(at: p)
                if let pruned = LayoutTree.removing(pane: paneID, from: sess.layout) {
                    sess.layout = pruned
                    if sess.activePane == paneID {
                        sess.activePane = LayoutTree.leafOrder(of: pruned).first ?? 0
                    }
                }
                if sess.zoomedPane == paneID { sess.zoomedPane = nil }
            }
        }
        guard let moved = entry else { return false }
        guard let split = LayoutTree.splitting(
            pane: destSess.activePane, adding: paneID, horizontal: false,
            in: destSess.layout) else {
            // Shouldn't happen; re-add to source as a safety net is complex —
            // land it as the destination's only recovery: tiled re-insert.
            withSession(destName) { sess in
                sess.panes.append(moved)
                sess.layout = LayoutTree.inserting(pane: paneID, into: sess.layout)
                sess.activePane = paneID
            }
            emit(.structure(session: sourceName))
            emit(.structure(session: destName))
            return true
        }
        withSession(destName) { sess in
            sess.panes.append(moved)
            sess.layout = split
            sess.activePane = paneID
            sess.zoomedPane = nil
        }
        emit(.structure(session: sourceName))
        emit(.structure(session: destName))
        return true
    }

    /// Move a pane's border (keyboard resize).
    public func resizePane(_ paneID: Int, direction: String, amount: Int) {
        guard let name = sessionName(ofPane: paneID),
              let sess = session(name) else { return }
        let resized = LayoutTree.resizing(
            pane: paneID, direction: direction, amount: amount, in: sess.layout)
        guard resized != sess.layout else { return }
        withSession(name) { sess in
            sess.layout = resized
        }
        emitGeometry(session: name)
    }

    /// The client viewport changed — renormalize the session to the new canvas.
    public func resizeCanvas(session name: String, cols: Int, rows: Int) {
        guard cols > 3, rows > 3, let sess = session(name),
              sess.cols != cols || sess.rows != rows else { return }
        withSession(name) { sess in
            sess.cols = cols
            sess.rows = rows
            sess.layout = LayoutTree.resized(sess.layout, w: cols, h: rows)
        }
        emitGeometry(session: name)
    }

    /// Even out the whole session into the tiled grid preset.
    public func applyTiled(session name: String) {
        guard let sess = session(name) else { return }
        let ordered = LayoutTree.leafOrder(of: sess.layout)
        guard let tree = LayoutTree.tiledPreset(panes: ordered, cols: sess.cols, rows: sess.rows)
        else { return }
        withSession(name) { sess in
            sess.layout = tree
        }
        emitGeometry(session: name)
    }

    private func emitGeometry(session name: String) {
        guard let sess = session(name) else { return }
        emit(.geometry(session: name, layout: sess.layout))
        scheduleSave()
    }

    // MARK: - Session-history catalog

    private func persistCatalogLocally() {
        if let data = try? JSONEncoder().encode(catalog) {
            UserDefaults.standard.set(data, forKey: catalogPersistKey)
        }
    }

    private func scheduleCatalogSave() {
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
    private func catalogUpsert(pane: PaneEntry, lastActive: Date? = nil) {
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
            for item in runtime.items {
                guard let message = item as? MessageItem, message.role == .user else { continue }
                let text = message.fullText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                if !text.isEmpty { return String(text.prefix(64)) }
            }
            if !runtime.title.isEmpty { return runtime.title }
        }
        return (pane.cwd as NSString).lastPathComponent
    }

    /// Turn-lifecycle hook: refresh lastActive when a turn has finished
    /// (throttled to 1s — onActivityChange fires on every state flip).
    private func catalogNoteActivity(paneID: Int) {
        guard let entry = paneEntry(paneID),
              let sid = entry.acpSessionID,
              let runtime = runtimes[paneID],
              !runtime.isTurnActive, runtime.lastStopReason != nil else { return }
        if let existing = catalog.entries[sid],
           Date().timeIntervalSince(existing.lastActive) < 1.0 { return }
        catalogUpsert(pane: entry, lastActive: Date())
    }

    /// A closing pane GRADUATES into the catalog: the agent process dies but
    /// the conversation lives on agent-side, reachable via respawn + load.
    private func catalogGraduate(pane: PaneEntry) {
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
        guard let sess = session(name) else { return nil }
        let newID = allocPane()
        let inserted = LayoutTree.inserting(pane: newID, into: sess.layout)
        guard LayoutTree.leafOrder(of: inserted).contains(newID) else { return nil }
        let (preset, startCommand) = Self.presetForCatalogID(entry.presetID)
        withSession(name) { sess in
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

    /// Open a history entry choosing the target session automatically: the
    /// session already holding it live, else `preferredSession` (the caller's
    /// attached session), else the most recently active session, else a
    /// fresh default one at the entry's directory. Returns where it landed.
    @discardableResult
    public func openHistorySession(
        _ entry: CatalogEntry, preferredSession: String? = nil
    ) -> (session: String, pane: Int)? {
        if let live = paneID(forACPSession: entry.acpSessionID),
           let name = sessionName(ofPane: live) {
            selectPane(live)
            return (name, live)
        }
        let target: String
        if let preferredSession, session(preferredSession) != nil {
            target = preferredSession
        } else if let recent = state.sessions.max(by: { $0.lastActivity < $1.lastActivity }) {
            target = recent.name
        } else {
            target = ensureSession("bento", cwd: entry.cwd)
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

    // MARK: - Snapshots (what the transitional bridge serializes)

    struct PaneSnapshot {
        var id: Int
        var width: Int
        var height: Int
        var x: Int
        var y: Int
        var paneActive: Bool
        var zoomed: Bool
        var command: String
        var title: String
    }

    func paneSnapshots(session name: String) -> [PaneSnapshot] {
        guard let sess = session(name) else { return [] }
        let frames = LayoutTree.frames(of: sess.layout)
        return LayoutTree.leafOrder(of: sess.layout).compactMap { paneID in
            guard let entry = sess.panes.first(where: { $0.id == paneID }),
                  let frame = frames[paneID] else { return nil }
            return PaneSnapshot(
                id: paneID,
                width: frame.w, height: frame.h, x: frame.x, y: frame.y,
                paneActive: sess.activePane == paneID,
                zoomed: sess.zoomedPane == paneID,
                command: presetFor(entry).command,
                title: paneTitle(entry))
        }
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

    // MARK: - Agent runtimes

    /// Create (or reuse) the runtime for a pane and launch/attach its agent.
    @discardableResult
    func spawn(paneID: Int) -> AgentSessionViewModel? {
        if let existing = runtimes[paneID] { return existing }
        guard let entry = paneEntry(paneID) else { return nil }
        let preset = presetFor(entry)
        let runtime = AgentSessionViewModel(preset: preset, cwd: entry.cwd)
        if let title = entry.title { runtime.title = title }
        // Seed the agent-side name from the catalog so a reopened
        // conversation is named immediately — the agent only re-sends
        // session_info_update at the next turn end.
        if let sid = entry.acpSessionID, let recorded = catalog.entries[sid],
           !recorded.title.isEmpty {
            runtime.sessionTitle = recorded.title
        }
        runtime.onActivityChange = { [weak self] in
            self?.emit(.activity(pane: paneID))
            self?.catalogNoteActivity(paneID: paneID)
        }
        runtime.onSessionTitleChange = { [weak self] in
            guard let self else { return }
            if let name = self.sessionName(ofPane: paneID) {
                self.emit(.structure(session: name))
            }
            if let entry = self.paneEntry(paneID) {
                self.catalogUpsert(pane: entry)
            }
        }
        runtime.onSessionLoadFailed = { [weak self] sessionID in
            // Resuming a recorded session drew an agent-side error: the
            // conversation was likely GC'd — grey its history entry.
            self?.markExpired(sessionID)
        }
        runtime.onRestartRequested = { [weak self] in
            self?.restartPane(paneID)
        }
        runtimes[paneID] = runtime
        guard launcher != nil else { return runtime }
        establish(runtime: runtime, paneID: paneID, entry: entry, preset: preset)
        return runtime
    }

    /// Drive a runtime through launch + bootstrap — the shared path for a fresh
    /// spawn AND an in-place restart. Prefers reattaching to the recorded
    /// daemon instance; on failure (daemon restarted / GC'd) it relaunches a
    /// fresh process and resumes the recorded ACP session — the agent's own
    /// storage carries the conversation.
    private func establish(runtime: AgentSessionViewModel, paneID: Int,
                           entry: PaneEntry, preset: ACPAgentPreset) {
        guard let launcher else { return }
        let bridge = runtime.makeBridge()
        let instanceID = entry.instanceID
        let resumeSessionID = entry.acpSessionID
        Task { [weak self] in
            do {
                let launch: AgentLaunch
                if let instanceID, let persistent = launcher as? any PersistentAgentLauncher {
                    do {
                        launch = try await persistent.attach(agentID: instanceID, handler: bridge)
                    } catch {
                        launch = try await launcher.launch(
                            preset: preset, cwd: entry.cwd, handler: bridge)
                    }
                    await runtime.bootstrapAttached(launch: launch, resumeSessionId: resumeSessionID)
                } else {
                    launch = try await launcher.launch(
                        preset: preset, cwd: entry.cwd, handler: bridge)
                    if launch.attachInfo != nil {
                        await runtime.bootstrapAttached(launch: launch, resumeSessionId: resumeSessionID)
                    } else {
                        await runtime.bootstrap(connection: launch.connection,
                                                resumeSessionId: resumeSessionID)
                    }
                }
                await MainActor.run {
                    self?.noteSpawned(paneID: paneID,
                                      instanceID: launch.attachInfo?.agentID,
                                      acpSessionID: runtime.sessionId)
                }
            } catch {
                await MainActor.run {
                    runtime.noteLaunchFailure(String(describing: error))
                    self?.emit(.activity(pane: paneID))
                }
            }
        }
    }

    /// Revive a stopped/failed pane in place: the daemon dropped its agent
    /// (crash, restart, GC) but the pane is still on screen. Reuses the SAME
    /// runtime object (surfaces bind it by identity) and resumes the recorded
    /// ACP conversation, so the pane and its view stay put. Wired to the
    /// restart affordance via `runtime.onRestartRequested`.
    public func restartPane(_ paneID: Int) {
        guard let runtime = runtimes[paneID], let entry = paneEntry(paneID) else { return }
        runtime.prepareForRestart()
        emit(.activity(pane: paneID))
        establish(runtime: runtime, paneID: paneID, entry: entry, preset: presetFor(entry))
    }

    /// Internal (not private) so structure tests can stamp session ids
    /// without spawning real agents.
    func noteSpawned(paneID: Int, instanceID: String?, acpSessionID: String?) {
        guard let name = sessionName(ofPane: paneID) else { return }
        withSession(name) { sess in
            guard let p = sess.panes.firstIndex(where: { $0.id == paneID }) else { return }
            if let instanceID { sess.panes[p].instanceID = instanceID }
            if let acpSessionID { sess.panes[p].acpSessionID = acpSessionID }
        }
        // The pane now has an ACP session: it exists in history from birth
        // (the "live" badge distinguishes it from closed ones).
        if acpSessionID != nil, let entry = paneEntry(paneID) {
            catalogUpsert(pane: entry, lastActive: Date())
        }
        emit(.activity(pane: paneID))
        emit(.structure(session: name))
    }

    /// Spawn runtimes for every pane of a session (attach flow).
    public func ensureRuntimes(session name: String) {
        guard let sess = session(name) else { return }
        for pane in sess.panes { spawn(paneID: pane.id) }
    }

    private func teardownRuntime(_ paneID: Int, killAgent: Bool) {
        guard let runtime = runtimes.removeValue(forKey: paneID) else { return }
        if killAgent { runtime.killAgent() }
        runtime.shutdown()
    }

    /// App shutdown: close connections only — daemon-hosted agents live on.
    public func shutdownAll() {
        for runtime in runtimes.values { runtime.shutdown() }
        runtimes.removeAll()
    }

    // MARK: - Composer / input routing (voice + send-keys equivalents)

    /// Raw key input routed to a chat pane: printable text lands in the
    /// composer; CR submits the draft (the voice compass's insert vs send).
    public func routeInput(_ data: Data, to paneID: Int) {
        guard let runtime = runtimes[paneID] else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        let isSubmit = text == "\r" || text == "\n" || text == "\r\n"
        if isSubmit {
            let draft = runtime.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.isEmpty else { return }
            runtime.composerDraft = ""
            runtime.send(draft)
        } else {
            let clean = text.replacingOccurrences(of: "\r", with: "\n")
            runtime.insertIntoComposer(clean.trimmingCharacters(in: .newlines))
        }
    }
}

extension ACPAgentPreset {
    var isBuiltin: Bool {
        ACPAgentPreset.builtin.contains { $0.id == id }
    }
}

extension AgentSessionViewModel {
    /// Surface a launcher failure through the normal failed-phase path.
    func noteLaunchFailure(_ message: String) {
        handleConnectionClosed(error: ACPError.malformedMessage(message))
    }
}
