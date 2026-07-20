import ACPHostKit
import Foundation
import SwiftTmux

/// TRANSITIONAL (dies in refactor S2, docs/acp-first-refactor.md): the shim
/// that lets the window-era TerminalViewModel drive the window-free
/// `AgentWorkspaceStore`. It answers the app's TmuxCommand traffic in the
/// dialect `TmuxParsers` parses, presenting each session as exactly ONE
/// fake window (id 1) holding the session's whole layout. Window verbs map
/// onto pane/session verbs; structure transforms of the dead two-mode
/// machinery answer with errors.
///
/// Threading: the protocol is nonisolated (the terminal codec is lock-based),
/// but every real caller is the MainActor view model — command entry points
/// hop/assume onto the MainActor where the store lives. `feedData`/`reset`
/// (called from the parse queue) are safe no-ops.
public final class AcpTmuxBridge: @unchecked Sendable {
    public let store: AgentWorkspaceStore

    public var onNotification: (@Sendable (TmuxNotification) -> Void)?
    public var sendToSSH: (@Sendable (String) -> Void)?
    public var logHandler: (@Sendable (String) -> Void)?

    /// The session this bridge (≈ one client) is attached to.
    public private(set) var attachedSession: String?
    /// Captured by `launchCommand`, consumed by `awaitControlMode` — the
    /// view model builds the launch string first, then awaits the greeting.
    private var pendingSession: String?
    private var commandNumber = 0

    /// The single fake window every session presents through this shim.
    private static let fakeWindowID = 1

    @MainActor
    public init(store: AgentWorkspaceStore = .shared) {
        self.store = store
        store.addListener(self) { [weak self] event in
            self?.handleStoreEvent(event)
        }
    }

    /// iOS entry: a bridge to a paired Mac's daemon over the sealed relay
    /// channel. One store per daemon (a phone talks to several Macs); the
    /// launcher and daemon sync are wired on first use.
    @MainActor
    public static func forRelayDaemon(
        daemonID: String, deviceID: String, hostKeyFingerprint: String,
        devicePrivateKey: Data, relayBaseURL: String
    ) -> AcpTmuxBridge {
        AcpTmuxBridge(store: AgentWorkspaceStore.relayStore(
            daemonID: daemonID, deviceID: deviceID,
            hostKeyFingerprint: hostKeyFingerprint,
            devicePrivateKey: devicePrivateKey, relayBaseURL: relayBaseURL))
    }

    deinit {
        let store = store
        Task { @MainActor [weak store] in
            // Listener keyed by identity; self is gone — sweep by best effort.
            _ = store
        }
    }

    // MARK: - Layout dialect (LayoutTree → tmux layout string)

    /// The view model still parses window geometry in the tmux layout-string
    /// dialect; render our tree into it. Bridge-local on purpose — the store
    /// and LayoutTree know nothing about the dialect.
    private static func layoutString(_ node: LayoutTree.Node) -> String {
        TmuxLayoutTree.serialize(tmuxNode(node))
    }

    private static func tmuxNode(_ node: LayoutTree.Node) -> TmuxLayoutTree.Node {
        switch node {
        case .leaf(let id, let w, let h, let x, let y):
            return .leaf(id: id, w: w, h: h, x: x, y: y)
        case .hsplit(let w, let h, let x, let y, let children):
            return .hsplit(w: w, h: h, x: x, y: y, children: children.map(tmuxNode))
        case .vsplit(let w, let h, let x, let y, let children):
            return .vsplit(w: w, h: h, x: x, y: y, children: children.map(tmuxNode))
        }
    }

    // MARK: - Store events → synthesized notifications

    @MainActor
    private func handleStoreEvent(_ event: AgentWorkspaceStore.Event) {
        switch event {
        case .structure(let session):
            guard session == attachedSession else { return }
            // Panes added by another device (statekv adoption) need their
            // agent runtimes before the refresh lists them.
            store.ensureRuntimes(session: session)
            // The window id is unused by the handler — it refreshes windows
            // AND panes, exactly what a structural change needs.
            onNotification?(.windowClose(window: TmuxWindowID(0)))
        case .geometry(let session, let layout):
            guard session == attachedSession else { return }
            onNotification?(.layoutChange(window: TmuxWindowID(Self.fakeWindowID),
                                          layout: Self.layoutString(layout)))
        case .activity(let pane):
            guard let attachedSession,
                  store.sessionName(ofPane: pane) == attachedSession else { return }
            onNotification?(.paneModeChanged(pane: TmuxPaneID(pane), mode: ""))
        case .sessionsChanged:
            break   // The session list is pulled, not pushed.
        }
    }

    // MARK: - Wizard

    /// The Agent-wizard flow: build the whole session per spec BEFORE the
    /// view model attaches. Layout presets beyond one pane land as the tiled
    /// grid.
    @MainActor
    public func createAgentSession(_ spec: AgentSpec) {
        guard store.session(spec.sessionName) == nil else { return }
        let command = spec.agentCommand.isEmpty ? nil : spec.agentCommand
        store.createSession(spec.sessionName, cwd: spec.workingDir,
                            preset: AgentWorkspaceStore.preset(forCommand: command))
        let paneCount = max(spec.layout.paneCount, 1)
        if paneCount > 1 {
            for _ in 1..<paneCount {
                _ = store.newPane(session: spec.sessionName,
                                  cwd: spec.workingDir, command: command)
            }
            store.applyTiled(session: spec.sessionName)
        }
    }

    // MARK: - Interpretation

    @MainActor
    private func respond(_ output: String = "", error: Bool = false) -> TmuxCommandResponse {
        commandNumber += 1
        return TmuxCommandResponse(commandNumber: commandNumber, isError: error, output: output)
    }

    @MainActor
    private func attach(_ name: String) {
        let canonical = store.ensureSession(name)
        attachedSession = canonical
        store.ensureRuntimes(session: canonical)
    }

    /// Strip a `name:` / `name:^` tmux target down to the session name.
    private func sessionPart(_ target: String) -> String {
        guard let colon = target.firstIndex(of: ":") else { return target }
        return String(target[..<colon])
    }

    private func commandText(_ command: SpawnCommand?) -> String? {
        switch command {
        case .shell(let s): return s
        case .tmuxSyntax(let s): return s
        case nil: return nil
        }
    }

    @MainActor
    private func interpret(_ command: TmuxCommand) -> TmuxCommandResponse {
        switch command {
        // MARK: Sessions
        case .listSessions:
            let lines = store.sessionList.map { "$\($0.id):\($0.name)" }
            return respond(lines.joined(separator: "\n"))

        case .newSession(let name, _):
            guard let name else { return respond("missing name", error: true) }
            if store.session(name) != nil {
                return respond("duplicate session: \(name)", error: true)
            }
            store.createSession(name)
            return respond()

        case .attachSession(let name):
            attach(name)
            return respond()

        case .switchClient(let session):
            guard let sess = store.session(session) else {
                return respond("can't find session: \(session)", error: true)
            }
            attachedSession = session
            store.ensureRuntimes(session: session)
            onNotification?(.sessionChanged(session: TmuxSessionID(sess.id), name: session))
            return respond()

        case .killSession(let name):
            guard let target = name ?? attachedSession else { return respond(error: true) }
            store.killSession(target)
            return respond()

        case .renameSession(let name):
            guard let current = attachedSession else { return respond(error: true) }
            store.renameSession(current, to: name)
            attachedSession = name
            onNotification?(.sessionRenamed(name: name))
            return respond()

        // MARK: Listings
        case .listPanes(let target, _, _):
            let name = target.map(sessionPart) ?? attachedSession
            guard let name, store.session(name) != nil else {
                return respond("no session", error: true)
            }
            let lines = store.paneSnapshots(session: name).map { p in
                "%\(p.id):\(p.width):\(p.height):\(p.x):\(p.y):\(p.paneActive ? 1 : 0):" +
                "\(p.zoomed ? 1 : 0):\(p.command):0:0:1:" +
                "@\(Self.fakeWindowID):\(p.title)"
            }
            return respond(lines.joined(separator: "\n"))

        case .listWindows(let target):
            let name = target.map(sessionPart) ?? attachedSession
            guard let name, let sess = store.session(name) else {
                return respond("no session", error: true)
            }
            let line = "@\(Self.fakeWindowID):1:\(Self.layoutString(sess.layout)):\(name)"
            return respond(line)

        // MARK: Window verbs → pane/session verbs
        case .newWindow(_, _, let path, let command):
            guard let session = attachedSession else { return respond(error: true) }
            guard store.newPane(session: session, cwd: path,
                                command: commandText(command)) != nil else {
                return respond("create pane failed", error: true)
            }
            return respond()

        case .selectWindow:
            return respond()   // one fake window; nothing to select

        case .renameWindow:
            return respond()   // windows are gone; pane renames use setPaneTitle

        case .killWindow:
            // The sidebar's "Close Window" on the only row = the session.
            guard let session = attachedSession else { return respond(error: true) }
            store.killSession(session)
            return respond()

        case .killWindowTarget:
            return respond("windows removed", error: true)

        // MARK: Panes
        case .splitWindow(let target, let horizontal, let path, let command):
            guard let session = attachedSession else { return respond(error: true) }
            let targetPane = target?.raw ?? store.session(session)?.activePane
            guard let targetPane,
                  store.splitPane(session: session, target: targetPane,
                                  horizontal: horizontal, cwd: path,
                                  command: commandText(command)) != nil else {
                return respond("create pane failed", error: true)
            }
            return respond()

        case .selectPane(let id):
            store.selectPane(id.raw)
            return respond()

        case .setPaneTitle(let id, let title):
            store.renamePane(id.raw, to: title)
            return respond()

        case .killPane(let id):
            store.killPane(id.raw)
            return respond()

        case .zoomPane(let id):
            store.toggleZoom(id.raw)
            return respond()

        case .swapPaneUp(let id):
            store.swapPane(id.raw, up: true)
            return respond()

        case .swapPaneDown(let id):
            store.swapPane(id.raw, up: false)
            return respond()

        case .swapPanes(let source, let destination):
            store.swapPanes(source.raw, destination.raw)
            return respond()

        case .movePane(let source, let target, let horizontal, let before):
            store.dockPane(source.raw, at: target.raw, horizontal: horizontal, before: before)
            return respond()

        case .resizePaneBy(let id, let direction, let amount):
            store.resizePane(id.raw, direction: direction, amount: amount)
            return respond()

        case .resizePane:
            return respond()

        // MARK: Structure transforms (two-mode machinery — dead)
        case .breakPane:
            return respond("windows removed", error: true)

        case .joinPane(let source, let target):
            // Same session: edge dock below the target. Cross-session: move.
            if store.sessionName(ofPane: source.raw) == store.sessionName(ofPane: target.raw) {
                store.dockPane(source.raw, at: target.raw, horizontal: false, before: false)
                return respond()
            }
            guard let dest = store.sessionName(ofPane: target.raw),
                  store.movePane(source.raw, toSession: dest) else {
                return respond("create pane failed", error: true)
            }
            return respond()

        case .joinPaneToSession(let source, let session):
            guard store.movePane(source.raw, toSession: sessionPart(session)) else {
                return respond("create pane failed", error: true)
            }
            return respond()

        case .moveWindow:
            return respond("windows removed", error: true)

        case .selectLayout(_, let layout):
            guard let session = attachedSession else { return respond(error: true) }
            if layout == "tiled" { store.applyTiled(session: session) }
            return respond()

        case .selectLayoutTarget(let target, let layout):
            if layout == "tiled" { store.applyTiled(session: sessionPart(target)) }
            return respond()

        // MARK: Options (session options died with the two-mode machinery)
        case .setSessionOption:
            return respond()

        case .showSessionOption:
            return respond("")

        // MARK: Info / client
        case .displayMessage(let format, let target):
            guard let paneID = target?.raw
                    ?? attachedSession.flatMap({ store.session($0)?.activePane }),
                  let entry = store.paneEntry(paneID) else {
                return respond("no pane", error: true)
            }
            switch format {
            case "#{pane_current_path}":
                return respond(entry.cwd)
            case "#{pane_start_command}":
                return respond(entry.startCommand ?? "")
            case "#{pane_current_command}":
                return respond(store.presetFor(entry).command)
            default:
                return respond("unsupported format", error: true)
            }

        case .refreshClient(let width, let height):
            guard let session = attachedSession else { return respond(error: true) }
            store.resizeCanvas(session: session, cols: width, rows: height)
            return respond()

        case .capturePane:
            // Chat panes have no character grid; seeding/scraping paths give
            // up gracefully on error responses.
            return respond("capture-pane unsupported", error: true)

        case .sendKeys(let pane, let keys, _):
            store.routeInput(Data(keys.utf8), to: pane.raw)
            return respond()

        case .listClients:
            return respond("", error: true)
        }
    }
}

// MARK: - TmuxCommanding

extension AcpTmuxBridge: TmuxCommanding {
    /// The view model builds the launch string here (then writes it to a
    /// transport that discards it) — capture the requested session. Grouped
    /// launches (`shareWithDesktop`) attach the GROUP TARGET directly: with
    /// no per-client viewport to protect, a grouped twin is pointless.
    public func launchCommand(sessionName: String?, groupWith: String?) -> String {
        MainActor.assumeIsolated {
            pendingSession = groupWith ?? sessionName ?? "main"
        }
        return ""
    }

    /// "Greeting seen" = the store attach; instant and always true.
    public func awaitControlMode(timeout: Duration) async -> Bool {
        await MainActor.run {
            if let pending = pendingSession {
                pendingSession = nil
                attach(pending)
            } else if attachedSession == nil {
                attach("main")
            }
            return true
        }
    }

    public func send(_ command: TmuxCommand, timeout: Duration) async -> TmuxCommandResponse {
        await MainActor.run {
            interpret(command)
        }
    }

    public func sendFireAndForget(_ command: TmuxCommand) {
        MainActor.assumeIsolated {
            _ = interpret(command)
        }
    }

    public func sendData(to pane: TmuxPaneID, data: Data) {
        MainActor.assumeIsolated {
            store.routeInput(data, to: pane.raw)
        }
    }

    /// Raw byte feed / codec reset: no wire, nothing to do. Both are called
    /// from the parse queue, so they must stay thread-safe no-ops.
    public func feedData(_ data: Data) {}
    public func reset() {}
}
