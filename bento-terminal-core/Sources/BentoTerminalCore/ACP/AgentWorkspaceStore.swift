import ACPKit
import ACPHostKit
import Foundation
import SwiftTmux

/// The tmux-server replacement for the ACP backend: one process-wide store
/// owning the session ⊃ window ⊃ pane structure, per-window layout trees
/// (tmux cell semantics via TmuxLayoutTree), and each pane's live agent
/// runtime (AgentSessionViewModel). `AcpTmuxBridge` translates the app's
/// TmuxCommand traffic onto this store, so TerminalViewModel and every view
/// keep their original shapes.
///
/// Persistence: the STRUCTURE persists here (UserDefaults for now; the
/// daemon's statekv takes over for multi-device). The AGENT PROCESSES persist
/// in the daemon (acphost instance registry) — pane records carry the
/// instance id so a restart reattaches instead of respawning.
@MainActor
public final class AgentWorkspaceStore {
    public static let shared = AgentWorkspaceStore()

    /// Mutation fan-out for attached bridges (one per app window).
    public enum Event {
        /// Panes/windows appeared, disappeared or moved — full refresh.
        case structure(session: String)
        /// Pure geometry change of one window (divider drag, canvas resize).
        case geometry(session: String, window: TmuxWindowID, layout: String)
        /// A pane's turn-lifecycle state changed (working/awaiting/idle).
        case activity(pane: TmuxPaneID)
        /// The session list itself changed (created/killed/renamed).
        case sessionsChanged
    }
    /// Multiple bridges may listen (multiple windows); keyed by ObjectIdentifier.
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
        var windowID: Int
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
    }

    struct WindowEntry: Codable {
        var id: Int
        var name: String
        var layout: String
        var activePane: Int
        var zoomed: Bool
    }

    struct SessionEntry: Codable {
        var id: Int
        var name: String
        var windows: [WindowEntry]
        var panes: [PaneEntry]
        var activeWindow: Int
        var options: [String: String]
        var cols: Int
        var rows: Int
        /// Last mutation / agent activity — the menubar session list's
        /// relative-time column.
        var lastActivity: Date = Date()

        private enum CodingKeys: String, CodingKey {
            case id, name, windows, panes, activeWindow, options, cols, rows, lastActivity
        }

        init(id: Int, name: String, windows: [WindowEntry], panes: [PaneEntry],
             activeWindow: Int, options: [String: String], cols: Int, rows: Int) {
            self.id = id
            self.name = name
            self.windows = windows
            self.panes = panes
            self.activeWindow = activeWindow
            self.options = options
            self.cols = cols
            self.rows = rows
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            windows = try c.decode([WindowEntry].self, forKey: .windows)
            panes = try c.decode([PaneEntry].self, forKey: .panes)
            activeWindow = try c.decode(Int.self, forKey: .activeWindow)
            options = try c.decode([String: String].self, forKey: .options)
            cols = try c.decode(Int.self, forKey: .cols)
            rows = try c.decode(Int.self, forKey: .rows)
            lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity) ?? Date()
        }
    }

    struct State: Codable {
        var sessions: [SessionEntry] = []
        var nextPane = 1
        var nextWindow = 1
        var nextSession = 1
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
              let decoded = try? JSONDecoder().decode(State.self, from: data) else { return }
        state = decoded
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let data = try? JSONEncoder().encode(self.state) {
                UserDefaults.standard.set(data, forKey: self.persistKey)
                // Structure lives with the daemon (the tmux-server analogue):
                // mirror every save so restarts and other devices read the
                // same tree. Fire-and-forget; last write wins.
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
               let decoded = try? JSONDecoder().decode(State.self, from: data) {
                adopt(decoded)
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
              let decoded = try? JSONDecoder().decode(State.self, from: data) else { return }
        adopt(decoded)
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

    /// Session containing a pane (panes are globally unique, like tmux %N).
    func sessionName(ofPane paneID: Int) -> String? {
        state.sessions.first { $0.panes.contains { $0.id == paneID } }?.name
    }

    func sessionName(ofWindow windowID: Int) -> String? {
        state.sessions.first { $0.windows.contains { $0.id == windowID } }?.name
    }

    public func runtime(for paneID: TmuxPaneID) -> AgentSessionViewModel? {
        runtimes[paneID.raw]
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

    // MARK: - App-level overview (the menubar's session/window menu source —
    // what `tmux ls` + `tmux list-windows` fed before)

    public struct SessionOverview {
        public struct Window {
            public let index: Int
            public let name: String
            public let active: Bool
            public let paneCount: Int
        }
        public let name: String
        public let lastActivity: Date
        public let windows: [Window]
    }

    public var overview: [SessionOverview] {
        state.sessions.map { sess in
            SessionOverview(
                name: sess.name,
                lastActivity: sess.lastActivity,
                windows: sess.windows.enumerated().map { index, window in
                    let panes = sess.panes.filter { $0.windowID == window.id }
                    // Live naming, like the sidebar: a single-pane window is
                    // named by what's running in it.
                    let display = panes.count == 1
                        ? panes.first.map { paneTitle($0) } ?? window.name
                        : window.name
                    return SessionOverview.Window(
                        index: index, name: display,
                        active: window.id == sess.activeWindow,
                        paneCount: panes.count)
                })
        }
    }

    /// Select a window by its position in the session (the menu's submenu
    /// rows address windows by index, tmux-style).
    public func selectWindow(session name: String, index: Int) {
        guard let sess = session(name), sess.windows.indices.contains(index) else { return }
        selectWindow(sess.windows[index].id)
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

    /// Attach-or-create (tmux `new-session -A`): returns the session, creating
    /// it with one default-agent pane when missing.
    @discardableResult
    public func ensureSession(_ name: String, cwd: String? = nil,
                              preset: ACPAgentPreset? = nil) -> String {
        if session(name) != nil { return name }
        createSession(name, cwd: cwd, preset: preset)
        return name
    }

    /// tmux `new-session -d`: a fresh session with one pane.
    public func createSession(_ name: String, cwd: String? = nil,
                              preset: ACPAgentPreset? = nil) {
        guard session(name) == nil else { return }
        let paneID = allocPane()
        let windowID = allocWindow()
        let sessionID = state.nextSession
        state.nextSession += 1
        let useCwd = cwd ?? NSHomeDirectory()
        let usePreset = preset ?? Self.defaultPreset
        let layout = TmuxLayoutTree.single(pane: paneID, w: Self.defaultCols, h: Self.defaultRows)
        let pane = PaneEntry(
            id: paneID, windowID: windowID, presetID: usePreset.id,
            customPreset: usePreset.isBuiltin ? nil : usePreset,
            cwd: useCwd, title: nil, instanceID: nil, acpSessionID: nil,
            startCommand: nil)
        let window = WindowEntry(
            id: windowID, name: usePreset.name,
            layout: TmuxLayoutTree.serialize(layout),
            activePane: paneID, zoomed: false)
        state.sessions.append(SessionEntry(
            id: sessionID, name: name, windows: [window], panes: [pane],
            activeWindow: windowID, options: [:],
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

    // MARK: - Options (tmux session user options: @bento_mode etc.)

    public func option(_ key: String, session name: String) -> String? {
        let value = session(name)?.options[key]
        return (value?.isEmpty ?? true) ? nil : value
    }

    public func setOption(_ key: String, value: String, session name: String) {
        guard let idx = sessionIndex(name) else { return }
        if value.isEmpty {
            state.sessions[idx].options.removeValue(forKey: key)
        } else {
            state.sessions[idx].options[key] = value
        }
        scheduleSave()
    }

    // MARK: - Snapshots (what the bridge serializes for list-panes/windows)

    struct PaneSnapshot {
        var id: Int
        var width: Int
        var height: Int
        var x: Int
        var y: Int
        var paneActive: Bool
        var zoomed: Bool
        var command: String
        var windowActive: Bool
        var windowID: Int
        var title: String
    }

    struct WindowSnapshot {
        var id: Int
        var active: Bool
        var layout: String
        var name: String
    }

    func paneSnapshots(session name: String) -> [PaneSnapshot] {
        guard let sess = session(name) else { return [] }
        var out: [PaneSnapshot] = []
        for window in sess.windows {
            guard let tree = TmuxLayoutTree.parse(window.layout) else { continue }
            var frames: [Int: (w: Int, h: Int, x: Int, y: Int)] = [:]
            collectFrames(tree, into: &frames)
            // Leaf order = pane order within the window (tmux pane indexes).
            for paneID in TmuxLayoutTree.leafOrder(of: tree) {
                guard let entry = sess.panes.first(where: { $0.id == paneID }),
                      let frame = frames[paneID] else { continue }
                let preset = presetFor(entry)
                out.append(PaneSnapshot(
                    id: paneID,
                    width: frame.w, height: frame.h, x: frame.x, y: frame.y,
                    paneActive: window.activePane == paneID,
                    zoomed: window.zoomed,
                    command: preset.command,
                    windowActive: sess.activeWindow == window.id,
                    windowID: window.id,
                    title: paneTitle(entry)))
            }
        }
        return out
    }

    func windowSnapshots(session name: String) -> [WindowSnapshot] {
        guard let sess = session(name) else { return [] }
        return sess.windows.map {
            WindowSnapshot(id: $0.id, active: sess.activeWindow == $0.id,
                           layout: $0.layout, name: $0.name)
        }
    }

    private func collectFrames(_ node: TmuxLayoutTree.Node,
                               into frames: inout [Int: (w: Int, h: Int, x: Int, y: Int)]) {
        switch node {
        case .leaf(let id, let w, let h, let x, let y):
            frames[id] = (w, h, x, y)
        case .hsplit(_, _, _, _, let children), .vsplit(_, _, _, _, let children):
            for child in children { collectFrames(child, into: &frames) }
        }
    }

    func presetFor(_ entry: PaneEntry) -> ACPAgentPreset {
        entry.customPreset
            ?? ACPAgentPreset.builtin.first { $0.id == entry.presetID }
            ?? Self.defaultPreset
    }

    func paneTitle(_ entry: PaneEntry) -> String {
        if let title = entry.title, !title.isEmpty { return title }
        if let runtime = runtimes[entry.id], !runtime.title.isEmpty { return runtime.title }
        return (entry.cwd as NSString).lastPathComponent
    }

    // MARK: - Window / pane ops

    private func allocPane() -> Int {
        defer { state.nextPane += 1 }
        return state.nextPane
    }

    private func allocWindow() -> Int {
        defer { state.nextWindow += 1 }
        return state.nextWindow
    }

    private func withSession(_ name: String, _ body: (inout SessionEntry) -> Void) {
        guard let idx = sessionIndex(name) else { return }
        body(&state.sessions[idx])
        state.sessions[idx].lastActivity = Date()
        scheduleSave()
    }

    private func windowTree(_ sess: SessionEntry, _ windowID: Int) -> TmuxLayoutTree.Node? {
        sess.windows.first { $0.id == windowID }.flatMap { TmuxLayoutTree.parse($0.layout) }
    }

    private func setWindowTree(_ name: String, _ windowID: Int, _ tree: TmuxLayoutTree.Node) {
        withSession(name) { sess in
            guard let w = sess.windows.firstIndex(where: { $0.id == windowID }) else { return }
            sess.windows[w].layout = TmuxLayoutTree.serialize(tree)
        }
    }

    /// tmux split-window: split `target`'s cell; the new pane runs `preset`
    /// in `cwd` and becomes the window's active pane. Returns the new pane id.
    @discardableResult
    public func splitPane(session name: String, target: Int, horizontal: Bool,
                          cwd: String?, command: String?) -> Int? {
        guard let sess = session(name),
              let entry = sess.panes.first(where: { $0.id == target }),
              let tree = windowTree(sess, entry.windowID) else { return nil }
        let newID = allocPane()
        guard let split = TmuxLayoutTree.splitting(
            pane: target, adding: newID, horizontal: horizontal, in: tree) else { return nil }
        let preset = Self.preset(forCommand: command)
        let useCwd = cwd ?? entry.cwd
        withSession(name) { sess in
            sess.panes.append(PaneEntry(
                id: newID, windowID: entry.windowID, presetID: preset.id,
                customPreset: preset.isBuiltin ? nil : preset,
                cwd: useCwd, title: nil, instanceID: nil, acpSessionID: nil,
                startCommand: command))
            if let w = sess.windows.firstIndex(where: { $0.id == entry.windowID }) {
                sess.windows[w].layout = TmuxLayoutTree.serialize(split)
                sess.windows[w].activePane = newID
                sess.windows[w].zoomed = false
            }
        }
        spawn(paneID: newID)
        emit(.structure(session: name))
        return newID
    }

    /// tmux new-window: fresh window with one pane. Returns its window id.
    @discardableResult
    public func newWindow(session name: String, windowName: String?,
                          cwd: String?, command: String?) -> Int? {
        guard sessionIndex(name) != nil else { return nil }
        let paneID = allocPane()
        let windowID = allocWindow()
        let preset = Self.preset(forCommand: command)
        withSession(name) { sess in
            let layout = TmuxLayoutTree.single(pane: paneID, w: sess.cols, h: sess.rows)
            sess.panes.append(PaneEntry(
                id: paneID, windowID: windowID, presetID: preset.id,
                customPreset: preset.isBuiltin ? nil : preset,
                cwd: cwd ?? NSHomeDirectory(), title: nil, instanceID: nil,
                acpSessionID: nil, startCommand: command))
            sess.windows.append(WindowEntry(
                id: windowID, name: windowName ?? preset.name,
                layout: TmuxLayoutTree.serialize(layout),
                activePane: paneID, zoomed: false))
            sess.activeWindow = windowID
        }
        spawn(paneID: paneID)
        emit(.structure(session: name))
        return windowID
    }

    /// tmux kill-pane: kill the agent, collapse the cell; the window closes
    /// with its last pane (and the session with its last window — tmux rules).
    public func killPane(_ paneID: Int) {
        guard let name = sessionName(ofPane: paneID),
              let sess = session(name),
              let entry = sess.panes.first(where: { $0.id == paneID }) else { return }
        teardownRuntime(paneID, killAgent: true)
        let windowID = entry.windowID
        var windowDied = false
        withSession(name) { sess in
            sess.panes.removeAll { $0.id == paneID }
            guard let w = sess.windows.firstIndex(where: { $0.id == windowID }) else { return }
            let tree = TmuxLayoutTree.parse(sess.windows[w].layout)
            if let tree, let pruned = TmuxLayoutTree.removing(pane: paneID, from: tree) {
                sess.windows[w].layout = TmuxLayoutTree.serialize(pruned)
                if sess.windows[w].activePane == paneID {
                    sess.windows[w].activePane = TmuxLayoutTree.leafOrder(of: pruned).first ?? 0
                }
                sess.windows[w].zoomed = false
            } else {
                // Last pane: the window dies.
                sess.windows.remove(at: w)
                windowDied = true
                if sess.activeWindow == windowID {
                    sess.activeWindow = sess.windows.first?.id ?? 0
                }
            }
        }
        if windowDied, let sess = self.session(name), sess.windows.isEmpty {
            killSession(name)
            return
        }
        emit(.structure(session: name))
    }

    /// tmux kill-window.
    public func killWindow(_ windowID: Int) {
        guard let name = sessionName(ofWindow: windowID),
              let sess = session(name) else { return }
        let paneIDs = sess.panes.filter { $0.windowID == windowID }.map(\.id)
        for id in paneIDs { teardownRuntime(id, killAgent: true) }
        withSession(name) { sess in
            sess.panes.removeAll { $0.windowID == windowID }
            sess.windows.removeAll { $0.id == windowID }
            if sess.activeWindow == windowID {
                sess.activeWindow = sess.windows.first?.id ?? 0
            }
        }
        if let sess = self.session(name), sess.windows.isEmpty {
            killSession(name)
            return
        }
        emit(.structure(session: name))
    }

    /// Kill a session's lowest-id window — tmux target `name:^` (the fresh
    /// session's placeholder after a cross-session move).
    public func killLowestWindow(session name: String) {
        guard let sess = session(name),
              let lowest = sess.windows.min(by: { $0.id < $1.id }) else { return }
        killWindow(lowest.id)
    }

    public func selectPane(_ paneID: Int) {
        guard let name = sessionName(ofPane: paneID),
              let entry = paneEntry(paneID) else { return }
        withSession(name) { sess in
            guard let w = sess.windows.firstIndex(where: { $0.id == entry.windowID }) else { return }
            sess.windows[w].activePane = paneID
            sess.activeWindow = entry.windowID
        }
        emit(.structure(session: name))
    }

    public func selectWindow(_ windowID: Int) {
        guard let name = sessionName(ofWindow: windowID) else { return }
        withSession(name) { sess in
            sess.activeWindow = windowID
        }
        emit(.structure(session: name))
    }

    public func renameWindow(_ windowID: Int, to newName: String) {
        guard let name = sessionName(ofWindow: windowID) else { return }
        withSession(name) { sess in
            guard let w = sess.windows.firstIndex(where: { $0.id == windowID }) else { return }
            sess.windows[w].name = newName
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

    /// tmux resize-pane -Z (zoom toggle, per window).
    public func toggleZoom(_ paneID: Int) {
        guard let name = sessionName(ofPane: paneID),
              let entry = paneEntry(paneID) else { return }
        withSession(name) { sess in
            guard let w = sess.windows.firstIndex(where: { $0.id == entry.windowID }) else { return }
            sess.windows[w].zoomed.toggle()
            if sess.windows[w].zoomed { sess.windows[w].activePane = paneID }
        }
        emit(.structure(session: name))
    }

    /// tmux swap-pane -U/-D (positions trade; content follows ids).
    public func swapPane(_ paneID: Int, up: Bool) {
        guard let name = sessionName(ofPane: paneID),
              let entry = paneEntry(paneID),
              let sess = session(name),
              let tree = windowTree(sess, entry.windowID),
              let other = TmuxLayoutTree.neighbor(of: paneID, previous: up, in: tree)
        else { return }
        swapPanes(paneID, other)
    }

    /// tmux swap-pane -s -t.
    public func swapPanes(_ a: Int, _ b: Int) {
        guard a != b,
              let name = sessionName(ofPane: a),
              sessionName(ofPane: b) == name,
              let ea = paneEntry(a), let eb = paneEntry(b),
              ea.windowID == eb.windowID,
              let sess = session(name),
              let tree = windowTree(sess, ea.windowID) else { return }
        let swapped = TmuxLayoutTree.swapping(a, b, in: tree)
        setWindowTree(name, ea.windowID, swapped)
        emitGeometry(session: name, window: ea.windowID)
    }

    /// tmux move-pane: dock `source` against `target`'s edge (same window).
    public func dockPane(_ source: Int, at target: Int, horizontal: Bool, before: Bool) {
        guard let name = sessionName(ofPane: source),
              sessionName(ofPane: target) == name,
              let es = paneEntry(source), let et = paneEntry(target) else { return }
        guard let sess = session(name) else { return }
        if es.windowID == et.windowID {
            guard let tree = windowTree(sess, et.windowID),
                  let docked = TmuxLayoutTree.docking(
                      pane: source, at: target, horizontal: horizontal, before: before, in: tree)
            else { return }
            withSession(name) { sess in
                guard let w = sess.windows.firstIndex(where: { $0.id == et.windowID }) else { return }
                sess.windows[w].layout = TmuxLayoutTree.serialize(docked)
                sess.windows[w].activePane = source
            }
            emit(.structure(session: name))
        } else {
            // Cross-window: remove from source window, split target's cell.
            guard removePaneFromTree(source, session: name) else { return }
            guard let sess2 = session(name), let tree = windowTree(sess2, et.windowID),
                  let split = TmuxLayoutTree.splitting(
                      pane: target, adding: source, horizontal: horizontal,
                      newFirst: before, in: tree) else { return }
            withSession(name) { sess in
                guard let p = sess.panes.firstIndex(where: { $0.id == source }) else { return }
                sess.panes[p].windowID = et.windowID
                guard let w = sess.windows.firstIndex(where: { $0.id == et.windowID }) else { return }
                sess.windows[w].layout = TmuxLayoutTree.serialize(split)
                sess.windows[w].activePane = source
            }
            emit(.structure(session: name))
        }
    }

    /// tmux resize-pane -L/-R/-U/-D.
    public func resizePane(_ paneID: Int, direction: String, amount: Int) {
        guard let name = sessionName(ofPane: paneID),
              let entry = paneEntry(paneID),
              let sess = session(name),
              let tree = windowTree(sess, entry.windowID) else { return }
        let resized = TmuxLayoutTree.resizing(
            pane: paneID, direction: direction, amount: amount, in: tree)
        guard resized != tree else { return }
        setWindowTree(name, entry.windowID, resized)
        emitGeometry(session: name, window: entry.windowID)
    }

    /// tmux refresh-client -C WxH: the client viewport — renormalize every
    /// window of the session to the new canvas.
    public func resizeCanvas(session name: String, cols: Int, rows: Int) {
        guard cols > 3, rows > 3, let sess = session(name),
              sess.cols != cols || sess.rows != rows else { return }
        withSession(name) { sess in
            sess.cols = cols
            sess.rows = rows
            for w in sess.windows.indices {
                if let tree = TmuxLayoutTree.parse(sess.windows[w].layout) {
                    sess.windows[w].layout = TmuxLayoutTree.serialize(
                        TmuxLayoutTree.resized(tree, w: cols, h: rows))
                }
            }
        }
        for window in session(name)?.windows ?? [] {
            emitGeometry(session: name, window: window.id)
        }
    }

    /// tmux break-pane: move a pane out into its own new window (optionally
    /// in another session). Returns the new window id.
    @discardableResult
    public func breakPane(_ paneID: Int, windowName: String?, targetSession: String?) -> Int? {
        guard let sourceName = sessionName(ofPane: paneID) else { return nil }
        let destName = targetSession ?? sourceName
        guard sessionIndex(destName) != nil else { return nil }
        guard removePaneFromTree(paneID, session: sourceName) else { return nil }
        let windowID = allocWindow()
        var entry: PaneEntry?
        withSession(sourceName) { sess in
            if let p = sess.panes.firstIndex(where: { $0.id == paneID }) {
                entry = sess.panes.remove(at: p)
            }
        }
        guard var moved = entry else { return nil }
        moved.windowID = windowID
        let title = paneTitle(moved)
        withSession(destName) { sess in
            let layout = TmuxLayoutTree.single(pane: paneID, w: sess.cols, h: sess.rows)
            sess.panes.append(moved)
            sess.windows.append(WindowEntry(
                id: windowID, name: windowName ?? title,
                layout: TmuxLayoutTree.serialize(layout),
                activePane: paneID, zoomed: false))
            // break-pane -d keeps the client's current window; do the same.
        }
        cleanupEmptySession(sourceName, unless: destName)
        emit(.structure(session: sourceName))
        if destName != sourceName { emit(.structure(session: destName)) }
        return windowID
    }

    /// tmux join-pane: move `source` into `target`'s window, splitting the
    /// target's cell (stacked, like join-pane's default -v).
    @discardableResult
    public func joinPane(_ source: Int, ontoPane target: Int) -> Bool {
        guard source != target,
              let sourceName = sessionName(ofPane: source),
              let destName = sessionName(ofPane: target),
              let et = paneEntry(target) else { return false }
        guard let destSess = session(destName),
              let destTree = windowTree(destSess, et.windowID) else { return false }
        if let es = paneEntry(source), es.windowID == et.windowID {
            return false   // tmux: can't join a pane to its own window
        }
        guard removePaneFromTree(source, session: sourceName) else { return false }
        var entry: PaneEntry?
        withSession(sourceName) { sess in
            if let p = sess.panes.firstIndex(where: { $0.id == source }) {
                entry = sess.panes.remove(at: p)
            }
        }
        guard var moved = entry else { return false }
        // The tree may have changed while removing (same session): re-read.
        let freshTree = session(destName).flatMap { self.windowTree($0, et.windowID) } ?? destTree
        guard let split = TmuxLayoutTree.splitting(
            pane: target, adding: source, horizontal: false, in: freshTree) else {
            // Roll back is complex; re-add as its own window instead.
            moved.windowID = allocWindow()
            let fallbackID = moved.windowID
            let title = paneTitle(moved)
            withSession(destName) { sess in
                let layout = TmuxLayoutTree.single(pane: source, w: sess.cols, h: sess.rows)
                sess.panes.append(moved)
                sess.windows.append(WindowEntry(
                    id: fallbackID, name: title,
                    layout: TmuxLayoutTree.serialize(layout),
                    activePane: source, zoomed: false))
            }
            emit(.structure(session: destName))
            return false
        }
        moved.windowID = et.windowID
        withSession(destName) { sess in
            sess.panes.append(moved)
            guard let w = sess.windows.firstIndex(where: { $0.id == et.windowID }) else { return }
            sess.windows[w].layout = TmuxLayoutTree.serialize(split)
        }
        cleanupEmptySession(sourceName, unless: destName)
        emit(.structure(session: sourceName))
        if destName != sourceName { emit(.structure(session: destName)) }
        return true
    }

    /// tmux join-pane -t 'name:': move `source` into another session's
    /// CURRENT window, splitting its active pane.
    @discardableResult
    public func joinPane(_ source: Int, toSessionCurrentWindow destName: String) -> Bool {
        guard let destSess = session(destName),
              let window = destSess.windows.first(where: { $0.id == destSess.activeWindow })
        else { return false }
        return joinPane(source, ontoPane: window.activePane)
    }

    /// tmux move-window -t 'name:': relocate a whole window across sessions.
    @discardableResult
    public func moveWindow(_ windowID: Int, toSession destName: String) -> Bool {
        guard let sourceName = sessionName(ofWindow: windowID),
              sourceName != destName,
              sessionIndex(destName) != nil else { return false }
        var window: WindowEntry?
        var panes: [PaneEntry] = []
        withSession(sourceName) { sess in
            if let w = sess.windows.firstIndex(where: { $0.id == windowID }) {
                window = sess.windows.remove(at: w)
            }
            panes = sess.panes.filter { $0.windowID == windowID }
            sess.panes.removeAll { $0.windowID == windowID }
            if sess.activeWindow == windowID {
                sess.activeWindow = sess.windows.first?.id ?? 0
            }
        }
        guard let moved = window else { return false }
        withSession(destName) { sess in
            sess.windows.append(moved)
            sess.panes.append(contentsOf: panes)
        }
        cleanupEmptySession(sourceName, unless: destName)
        emit(.structure(session: sourceName))
        emit(.structure(session: destName))
        return true
    }

    /// tmux select-layout: apply a serialized layout (or the "tiled" preset)
    /// to a window. Panes are assigned to leaves IN WINDOW ORDER, ignoring
    /// the ids embedded in the string — exactly tmux's semantics, which the
    /// merge-back logic depends on.
    public func applyLayout(_ windowID: Int, layout: String) {
        guard let name = sessionName(ofWindow: windowID),
              let sess = session(name) else { return }
        let panes = sess.panes.filter { $0.windowID == windowID }.map(\.id)
        guard !panes.isEmpty else { return }
        // Window order = current tree leaf order (stable across edits).
        let ordered: [Int]
        if let current = windowTree(sess, windowID) {
            let order = TmuxLayoutTree.leafOrder(of: current)
            ordered = order.filter { panes.contains($0) } + panes.filter { !order.contains($0) }
        } else {
            ordered = panes
        }
        let tree: TmuxLayoutTree.Node?
        if layout == "tiled" {
            tree = Self.tiledPreset(panes: ordered, cols: sess.cols, rows: sess.rows)
        } else if let parsed = TmuxLayoutTree.parse(layout) {
            // Reassign leaves to the window's panes in order.
            let leaves = TmuxLayoutTree.leafOrder(of: parsed)
            guard leaves.count == ordered.count else { return }
            var mapping: [Int: Int] = [:]
            for (from, to) in zip(leaves, ordered) { mapping[from] = to }
            tree = Self.remapLeaves(parsed, mapping: mapping)
        } else {
            tree = nil
        }
        guard let applied = tree else { return }
        setWindowTree(name, windowID, TmuxLayoutTree.resized(applied, w: sess.cols, h: sess.rows))
        emitGeometry(session: name, window: windowID)
    }

    /// Apply "tiled" to a session's CURRENT window (target `name:`).
    public func applyLayoutToCurrentWindow(session name: String, layout: String) {
        guard let sess = session(name) else { return }
        applyLayout(sess.activeWindow, layout: layout)
    }

    /// tmux's `tiled` preset: as square a grid as fits, rows filled top-down.
    static func tiledPreset(panes: [Int], cols: Int, rows: Int) -> TmuxLayoutTree.Node? {
        guard let first = panes.first else { return nil }
        guard panes.count > 1 else {
            return .leaf(id: first, w: cols, h: rows, x: 0, y: 0)
        }
        let columns = Int(Double(panes.count).squareRoot().rounded(.up))
        let rowCount = Int((Double(panes.count) / Double(columns)).rounded(.up))
        var rowsNodes: [TmuxLayoutTree.Node] = []
        var index = 0
        for _ in 0..<rowCount {
            let slice = panes[index..<min(index + columns, panes.count)]
            index += slice.count
            let leaves = slice.map { TmuxLayoutTree.Node.leaf(id: $0, w: 1, h: 1, x: 0, y: 0) }
            if leaves.count == 1 {
                rowsNodes.append(leaves[0])
            } else {
                rowsNodes.append(.hsplit(w: cols, h: 1, x: 0, y: 0, children: leaves))
            }
        }
        let root: TmuxLayoutTree.Node
        if rowsNodes.count == 1 {
            root = rowsNodes[0]
        } else {
            root = .vsplit(w: cols, h: rows, x: 0, y: 0, children: rowsNodes)
        }
        return TmuxLayoutTree.resized(root, w: cols, h: rows)
    }

    static func remapLeaves(_ node: TmuxLayoutTree.Node, mapping: [Int: Int]) -> TmuxLayoutTree.Node {
        switch node {
        case .leaf(let id, let w, let h, let x, let y):
            return .leaf(id: mapping[id] ?? id, w: w, h: h, x: x, y: y)
        case .hsplit(let w, let h, let x, let y, let children):
            return .hsplit(w: w, h: h, x: x, y: y,
                           children: children.map { remapLeaves($0, mapping: mapping) })
        case .vsplit(let w, let h, let x, let y, let children):
            return .vsplit(w: w, h: h, x: x, y: y,
                           children: children.map { remapLeaves($0, mapping: mapping) })
        }
    }

    // MARK: - Structural helpers

    /// Remove a pane's leaf from its window tree; a window emptied of panes
    /// is dropped. Pane ENTRY stays (caller decides where it goes).
    private func removePaneFromTree(_ paneID: Int, session name: String) -> Bool {
        guard let sess = session(name),
              let entry = sess.panes.first(where: { $0.id == paneID }),
              let tree = windowTree(sess, entry.windowID) else { return false }
        let windowID = entry.windowID
        if let pruned = TmuxLayoutTree.removing(pane: paneID, from: tree) {
            withSession(name) { sess in
                guard let w = sess.windows.firstIndex(where: { $0.id == windowID }) else { return }
                sess.windows[w].layout = TmuxLayoutTree.serialize(pruned)
                if sess.windows[w].activePane == paneID {
                    sess.windows[w].activePane = TmuxLayoutTree.leafOrder(of: pruned).first ?? 0
                }
            }
        } else {
            // Only pane: its window dies.
            withSession(name) { sess in
                sess.windows.removeAll { $0.id == windowID }
                if sess.activeWindow == windowID {
                    sess.activeWindow = sess.windows.first?.id ?? 0
                }
            }
        }
        return true
    }

    /// tmux rule: a session whose last window left/died ends. `unless` guards
    /// the destination of a move (never kill where content just landed).
    private func cleanupEmptySession(_ name: String, unless keep: String) {
        guard name != keep, let sess = session(name), sess.windows.isEmpty else { return }
        killSession(name)
    }

    private func emitGeometry(session name: String, window windowID: Int) {
        guard let sess = session(name),
              let window = sess.windows.first(where: { $0.id == windowID }) else { return }
        emit(.geometry(session: name, window: TmuxWindowID(windowID), layout: window.layout))
        scheduleSave()
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
            self?.emit(.activity(pane: TmuxPaneID(paneID)))
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
                    self?.emit(.activity(pane: TmuxPaneID(paneID)))
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
        emit(.activity(pane: TmuxPaneID(paneID)))
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
