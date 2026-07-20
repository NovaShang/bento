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

    private var saveScheduled = false
    /// Long-lived control channel to the daemon (statekv + instance list).
    private var control: AcpHostTransport?
    private static let stateKey = "workspace"

    public init(persistKey: String = "acp_workspace_v1") {
        self.persistKey = persistKey
        load()
    }

    // MARK: - Persistence

    private func load() {
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
                // Structure lives with the daemon: mirror every save so
                // restarts and other devices read the same tree.
                // Fire-and-forget; last write wins.
                self.control?.setState(key: Self.stateKey, data: data)
            }
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
                    guard case .stateChanged(let key) = event, key == Self.stateKey else { return }
                    Task { @MainActor [weak self] in
                        await self?.pullRemoteState()
                    }
                }
            }
            if let data = try await transport.getState(key: Self.stateKey),
               let decoded = Self.decodeState(data) {
                adopt(decoded.state)
                // A migrated (window-era) daemon blob gets rewritten at v2 so
                // every device converges on the new schema.
                if decoded.migrated { scheduleSave() }
            } else if let data = try? JSONEncoder().encode(state) {
                transport.setState(key: Self.stateKey, data: data)
            }
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

    public func renamePane(_ paneID: Int, to title: String) {
        guard let name = sessionName(ofPane: paneID) else { return }
        withSession(name) { sess in
            guard let p = sess.panes.firstIndex(where: { $0.id == paneID }) else { return }
            sess.panes[p].title = title
        }
        runtimes[paneID]?.title = title
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
        if let custom = entry.customPreset {
            // Legacy records can carry terminal-era TUI commands ("claude");
            // route them through the alias table so the pane speaks ACP.
            if let aliasID = Self.commandAliases[custom.command],
               let builtin = ACPAgentPreset.builtin.first(where: { $0.id == aliasID }) {
                return builtin
            }
            return custom
        }
        return ACPAgentPreset.builtin.first { $0.id == entry.presetID } ?? Self.defaultPreset
    }

    func paneTitle(_ entry: PaneEntry) -> String {
        if let title = entry.title, !title.isEmpty { return title }
        if let runtime = runtimes[entry.id], !runtime.title.isEmpty { return runtime.title }
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
        runtime.onActivityChange = { [weak self] in
            self?.emit(.activity(pane: paneID))
        }
        runtimes[paneID] = runtime
        guard let launcher else {
            return runtime
        }
        let bridge = SessionConnectionBridge()
        bridge.session = runtime
        let instanceID = entry.instanceID
        let resumeSessionID = entry.acpSessionID
        Task { [weak self] in
            do {
                let launch: AgentLaunch
                if let instanceID, let persistent = launcher as? any PersistentAgentLauncher {
                    do {
                        launch = try await persistent.attach(agentID: instanceID, handler: bridge)
                    } catch {
                        // Instance gone (daemon restarted / GC'd): respawn a
                        // fresh process and resume the recorded ACP session —
                        // the agent's own storage carries the conversation.
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
        return runtime
    }

    private func noteSpawned(paneID: Int, instanceID: String?, acpSessionID: String?) {
        guard let name = sessionName(ofPane: paneID) else { return }
        withSession(name) { sess in
            guard let p = sess.panes.firstIndex(where: { $0.id == paneID }) else { return }
            if let instanceID { sess.panes[p].instanceID = instanceID }
            if let acpSessionID { sess.panes[p].acpSessionID = acpSessionID }
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
