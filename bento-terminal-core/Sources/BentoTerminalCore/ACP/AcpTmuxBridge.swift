import Foundation
import SwiftTmux

/// The ACP backend behind TerminalViewModel: a `TmuxCommanding` that
/// interprets the app's TmuxCommand traffic against `AgentWorkspaceStore`
/// instead of a tmux server. Command sites in the view model stay literally
/// unchanged; list responses are serialized in the exact formats
/// `TmuxParsers` already parses; store mutations come back as synthesized
/// control-mode notifications, driving the original refresh pipeline.
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

    /// The session this bridge (≈ one tmux client) is attached to.
    public private(set) var attachedSession: String?
    /// Captured by `launchCommand`, consumed by `awaitControlMode` — the
    /// view model builds the launch string first, then awaits the greeting.
    private var pendingSession: String?
    private var commandNumber = 0

    @MainActor
    public init(store: AgentWorkspaceStore = .shared) {
        self.store = store
        store.addListener(self) { [weak self] event in
            self?.handleStoreEvent(event)
        }
    }

    deinit {
        let store = store
        Task { @MainActor [weak store] in
            // Listener keyed by identity; self is gone — sweep by best effort.
            _ = store
        }
    }

    // MARK: - Store events → synthesized notifications

    @MainActor
    private func handleStoreEvent(_ event: AgentWorkspaceStore.Event) {
        switch event {
        case .structure(let session):
            guard session == attachedSession else { return }
            // The window id is unused by the handler — it refreshes windows
            // AND panes, exactly what a structural change needs.
            onNotification?(.windowClose(window: TmuxWindowID(0)))
        case .geometry(let session, let window, let layout):
            guard session == attachedSession else { return }
            onNotification?(.layoutChange(window: window, layout: layout))
        case .activity(let pane):
            guard let attachedSession,
                  store.sessionName(ofPane: pane.raw) == attachedSession else { return }
            onNotification?(.paneModeChanged(pane: pane, mode: ""))
        case .sessionsChanged:
            break   // The session list is pulled, not pushed.
        }
    }

    // MARK: - Wizard

    /// The Agent-wizard flow: build the whole session per spec BEFORE the
    /// view model attaches (the terminal path ran spec.setupScript through
    /// the shell). Layout presets beyond one pane land as tmux's `tiled`.
    @MainActor
    public func createAgentSession(_ spec: AgentSpec) {
        guard store.session(spec.sessionName) == nil else { return }
        let command = spec.agentCommand.isEmpty ? nil : spec.agentCommand
        store.createSession(spec.sessionName, cwd: spec.workingDir,
                            preset: AgentWorkspaceStore.preset(forCommand: command))
        let paneCount = max(spec.layout.paneCount, 1)
        if paneCount > 1 {
            for _ in 1..<paneCount {
                guard let sess = store.session(spec.sessionName),
                      let win = sess.windows.first(where: { $0.id == sess.activeWindow })
                else { break }
                _ = store.splitPane(session: spec.sessionName, target: win.activePane,
                                    horizontal: true, cwd: spec.workingDir, command: command)
            }
            store.applyLayoutToCurrentWindow(session: spec.sessionName, layout: "tiled")
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
                "\(p.zoomed ? 1 : 0):\(p.command):0:0:\(p.windowActive ? 1 : 0):" +
                "@\(p.windowID):\(p.title)"
            }
            return respond(lines.joined(separator: "\n"))

        case .listWindows(let target):
            let name = target.map(sessionPart) ?? attachedSession
            guard let name, store.session(name) != nil else {
                return respond("no session", error: true)
            }
            let lines = store.windowSnapshots(session: name).map { w in
                "@\(w.id):\(w.active ? 1 : 0):\(w.layout):\(w.name)"
            }
            return respond(lines.joined(separator: "\n"))

        // MARK: Windows
        case .newWindow(_, let name, let path, let command):
            guard let session = attachedSession else { return respond(error: true) }
            _ = store.newWindow(session: session, windowName: name,
                                cwd: path, command: commandText(command))
            return respond()

        case .selectWindow(let id):
            store.selectWindow(id.raw)
            return respond()

        case .renameWindow(let id, let name):
            store.renameWindow(id.raw, to: name)
            return respond()

        case .killWindow(let id):
            store.killWindow(id.raw)
            return respond()

        case .killWindowTarget(let target):
            store.killLowestWindow(session: sessionPart(target))
            return respond()

        // MARK: Panes
        case .splitWindow(let target, let horizontal, let path, let command):
            guard let session = attachedSession else { return respond(error: true) }
            let targetPane = target?.raw
                ?? store.session(session).flatMap { sess in
                    sess.windows.first { $0.id == sess.activeWindow }?.activePane
                }
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

        // MARK: Structure transforms
        case .breakPane(let source, let name, let targetSession):
            guard store.breakPane(source.raw, windowName: name,
                                  targetSession: targetSession.map(sessionPart)) != nil else {
                return respond("break-pane failed", error: true)
            }
            return respond()

        case .joinPane(let source, let target):
            guard store.joinPane(source.raw, ontoPane: target.raw) else {
                return respond("create pane failed", error: true)
            }
            return respond()

        case .joinPaneToSession(let source, let session):
            guard store.joinPane(source.raw, toSessionCurrentWindow: sessionPart(session)) else {
                return respond("create pane failed", error: true)
            }
            return respond()

        case .moveWindow(let id, let targetSession):
            guard store.moveWindow(id.raw, toSession: sessionPart(targetSession)) else {
                return respond("move-window failed", error: true)
            }
            return respond()

        case .selectLayout(let window, let layout):
            store.applyLayout(window.raw, layout: layout)
            return respond()

        case .selectLayoutTarget(let target, let layout):
            store.applyLayoutToCurrentWindow(session: sessionPart(target), layout: layout)
            return respond()

        // MARK: Options
        case .setSessionOption(let target, let name, let value):
            guard let session = target.map(sessionPart) ?? attachedSession else {
                return respond(error: true)
            }
            store.setOption(name, value: value, session: session)
            return respond()

        case .showSessionOption(let target, let name):
            guard let session = target.map(sessionPart) ?? attachedSession else {
                return respond(error: true)
            }
            return respond(store.option(name, session: session) ?? "")

        // MARK: Info / client
        case .displayMessage(let format, let target):
            guard let paneID = target?.raw
                    ?? attachedSession.flatMap({ name in
                        store.session(name).flatMap { sess in
                            sess.windows.first { $0.id == sess.activeWindow }?.activePane
                        }
                    }),
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
