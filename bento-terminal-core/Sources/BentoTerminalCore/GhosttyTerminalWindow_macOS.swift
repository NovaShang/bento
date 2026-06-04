#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftTmux

/// Opens native libghostty terminal windows backed by a local pty. This is the
/// macOS terminal — it uses the *same* `GhosttyTerminalSurface` and tmux/runtime
/// stack as iOS; only the transport differs (local pty here vs SSH on iOS).
@MainActor
public enum BentoTerminalWindow {
    private static var controllers: [GhosttyTerminalWindowController] = []
    private static var plainControllers: [PlainTerminalWindowController] = []

    /// Default session name used by the bare "New Terminal Window" entry.
    public nonisolated static let defaultSessionName = "bento-mac"

    /// UserDefaults keys for session restore.
    nonisolated static let lastSessionsKey = "mac_last_terminal_sessions"
    nonisolated static let reopenAtLaunchKey = "terminal_reopen_at_launch"

    /// Reopen the tmux sessions that were open last run — but only if the user
    /// enabled "Reopen terminal sessions at launch". `.createOrAttach` reattaches
    /// to a still-running tmux session (restoring its windows/panes/scrollback)
    /// or recreates it if the server no longer has it. Call once at launch.
    public static func reopenLastSessionsIfEnabled() {
        guard UserDefaults.standard.bool(forKey: reopenAtLaunchKey) else { return }
        let names = UserDefaults.standard.stringArray(forKey: lastSessionsKey) ?? []
        for name in names where !name.isEmpty { newWindow(session: name) }
    }

    /// Persist the session names of the currently-open tmux terminal windows so
    /// `reopenLastSessionsIfEnabled` can restore them next launch.
    private static func persistOpenSessions() {
        let names = Array(Set(controllers.map(\.sessionKey)))
        UserDefaults.standard.set(names, forKey: lastSessionsKey)
    }

    /// Open a plain shell window with NO tmux (raw local pty, single surface).
    /// Useful to isolate rendering issues from the tmux -CC control-mode path.
    public static func newWindowNoTmux() {
        let controller = PlainTerminalWindowController()
        plainControllers.append(controller)
        controller.onClose = { [weak controller] in
            plainControllers.removeAll { $0 === controller }
            updateActivationPolicy()
        }
        controller.show()
    }

    /// Drop to a pure menubar (accessory) app when no terminal windows remain.
    static func updateActivationPolicy() {
        if controllers.isEmpty && plainControllers.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Open a new terminal window attached to (or creating) the named tmux
    /// session over a local pty + `tmux -CC`.
    public static func newWindow(session: String = defaultSessionName) {
        open(choice: .createOrAttach(name: session), title: titleFor(session))
    }

    /// Open a new terminal window that spins up a detached tmux session matching
    /// `spec` (working dir, agent command, layout) and attaches in control mode.
    /// This is the path the menubar Agent wizard uses to launch into the native
    /// terminal instead of bouncing to a third-party app.
    public static func newWindow(agent spec: AgentSpec) {
        open(choice: .createAgent(spec: spec), title: titleFor(spec.sessionName))
    }

    private static func open(choice: TmuxStartChoice, title: String) {
        let controller = GhosttyTerminalWindowController(choice: choice, title: title)
        controllers.append(controller)
        persistOpenSessions()
        controller.onClose = { [weak controller] in
            controllers.removeAll { $0 === controller }
            persistOpenSessions()
            // No terminal windows left → drop back to a pure menubar (accessory)
            // app: removes the Dock icon and app menu. (The app keeps running —
            // applicationShouldTerminateAfterLastWindowClosed is false.)
            updateActivationPolicy()
        }
        controller.show()
    }

    private static func titleFor(_ session: String) -> String {
        session == defaultSessionName ? "Bento Terminal" : "Bento · \(session)"
    }
}

@MainActor
final class GhosttyTerminalWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel: TerminalViewModel
    private let paneHost: GhosttyTiledPaneHost
    private var content: TerminalWindowContent?
    private var cancellables = Set<AnyCancellable>()
    private let choice: TmuxStartChoice
    private let windowTitle: String
    let sessionKey: String
    var onClose: (() -> Void)?

    init(choice: TmuxStartChoice, title: String) {
        self.choice = choice
        self.windowTitle = title
        switch choice {
        case .createOrAttach(let name): self.sessionKey = name
        case .createAgent(let spec): self.sessionKey = spec.sessionName
        case .shareWithDesktop(let target): self.sessionKey = target
        case .noTmux: self.sessionKey = "local"
        }
        let theme = ThemeStore.shared.makeTerminalTheme()
        // Same shared TerminalViewModel as iOS, driving tmux -CC over a local
        // pty. The tiled pane host (AppKit) is the only platform-specific view.
        // Awaiting-input callbacks surface a macOS notification + Dock badge
        // (reusing the same StateDetectionService path iOS drives a Live
        // Activity from).
        let key = sessionKey
        let env = TerminalEnvironment(
            idealTerminalSize: { (120, 30) },
            onSessionUpdate: { _, session, awaiting, prompt in
                MacAwaitingNotifier.shared.update(
                    sessionKey: session.isEmpty ? key : session,
                    awaiting: awaiting, prompt: prompt)
            }
        )
        let vm = TerminalViewModel(
            host: Host(name: "Local"),
            transport: LocalPtyTransport(command: nil),
            environment: env
        )
        self.viewModel = vm
        self.paneHost = GhosttyTiledPaneHost(viewModel: vm, theme: theme)
        super.init()
    }

    func show() {
        // Become a regular app while a terminal window is open so it gets a Dock
        // icon and the app menu bar. We drop back to .accessory when the last
        // window closes (see BentoTerminalWindow.open). The teardown crash that
        // used to kill the app on close is fixed, and
        // applicationShouldTerminateAfterLastWindowClosed=false keeps the menubar
        // app alive after the last window closes.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = windowTitle
        win.delegate = self
        // We hold the window in `window` and tear it down explicitly; let ARC
        // own its lifetime (avoids a release race during the close animation).
        win.isReleasedWhenClosed = false

        // Wrap the tiled host in a content view that adds a tmux window-tab strip
        // on top (shown only when there's >1 window). Tab click → selectWindow,
        // "+" → new tmux window.
        let content = TerminalWindowContent(host: paneHost)
        content.tabBar.onSelect = { [weak self] id in self?.viewModel.selectWindow(id) }
        content.tabBar.onNew = { [weak self] in self?.viewModel.newWindow() }
        self.content = content
        viewModel.$windows
            .combineLatest(viewModel.$activeWindowID)
            .receive(on: RunLoop.main)
            .sink { [weak content] windows, activeID in
                content?.update(windows: windows, activeID: activeID)
            }
            .store(in: &cancellables)

        win.contentView = content
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        // tmux -CC over the local pty → the shared VM produces PaneViewModels,
        // and GhosttyTiledPaneHost tiles them iTerm2-style.
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.connect()
            await self.viewModel.applyTmuxChoice(self.choice)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Stop rendering and free the ghostty surfaces BEFORE AppKit tears the
        // window down — otherwise the close animation commits a CoreAnimation
        // transaction against the half-freed Metal layer and crashes.
        cancellables.removeAll()
        paneHost.teardown()
        viewModel.disconnect()
        MacAwaitingNotifier.shared.clear(sessionKey: sessionKey)
        window?.delegate = nil
        content = nil
        window = nil
        onClose?()
    }

    /// Standard xterm 16-color palette (placeholder until ghostty palette
    /// configuration is wired in Phase 4).
    static let defaultAnsi: [UInt32] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]
}

/// A plain terminal window with NO tmux — a single libghostty surface bound
/// straight to a local-pty login shell (raw bytes, no `-CC` control mode, no
/// tiling host). Diagnostic / "just a terminal" option.
@MainActor
final class PlainTerminalWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel: TerminalViewModel
    private let surface: GhosttyTerminalSurface
    var onClose: (() -> Void)?

    override init() {
        let theme = ThemeStore.shared.makeTerminalTheme()
        let env = TerminalEnvironment(idealTerminalSize: { (120, 30) })
        self.viewModel = TerminalViewModel(
            host: Host(name: "Local"),
            transport: LocalPtyTransport(command: nil),
            environment: env)
        self.surface = GhosttyTerminalSurface(theme: theme)
        super.init()
    }

    func show() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Bento Terminal (no tmux)"
        win.delegate = self
        win.isReleasedWhenClosed = false

        // Raw single-pane wiring (mirrors the iOS non-tmux path): surface input →
        // pty, pty output → surface, surface grid → pty size.
        surface.onInput = { [weak viewModel] data in viewModel?.sendData(data) }
        surface.onSizeChanged = { [weak viewModel] size in
            viewModel?.resizeTerminal(cols: size.columns, rows: size.rows)
        }
        viewModel.onRawDataReceived = { [weak surface] data in
            DispatchQueue.main.async { surface?.feed(data) }
        }

        win.contentView = surface
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(surface)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.connect()
            await self.viewModel.applyTmuxChoice(.noTmux)
        }
    }

    func windowWillClose(_ notification: Notification) {
        surface.teardown()
        viewModel.disconnect()
        window?.delegate = nil
        window = nil
        onClose?()
    }
}
#endif
