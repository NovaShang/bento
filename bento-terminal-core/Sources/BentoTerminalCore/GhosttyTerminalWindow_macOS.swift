#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftTmux
import SwiftUI

/// Opens native libghostty terminals backed by a local pty + `tmux -CC`. macOS
/// uses the *same* runtime stack as iOS; only the transport differs.
///
/// Sessions are SELF-MANAGED tabs (not native macOS window tabs): a single
/// `TerminalWindowManager` hosts one NSWindow whose toolbar center holds a
/// Finder-style segmented `NSToolbarItemGroup`. Each tab is a live `SessionTab` (its tmux client +
/// surfaces stay alive in the background); switching just reparents the active
/// tab's pane host into the window, so switches are instant and state-preserving.
@MainActor
public enum BentoTerminalWindow {
    private static var manager: TerminalWindowManager?

    /// The session created when the window opens with no previous session.
    /// User-configurable (Settings → Sessions); defaults to the app name.
    public nonisolated static let defaultSessionNameKey = "default_session_name"
    private nonisolated static let fallbackDefaultSessionName = "bento"
    public nonisolated static var defaultSessionName: String {
        let raw = UserDefaults.standard.string(forKey: defaultSessionNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return fallbackDefaultSessionName }
        // tmux uses ':' and '.' as target separators — keep them out of names.
        return raw.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    /// App-provided hooks for toolbar actions that live in the app target.
    public static var onNewAgentSession: (() -> Void)?
    public static var onOpenSettings: (() -> Void)?
    public static var sessionsMenuProvider: (() -> NSMenu?)?
    /// Kill a tmux session by name via a one-shot CLI command (reliable —
    /// independent of any control-mode connection). Wired in the app target.
    public static var killSessionCLI: ((String) -> Void)?

    /// Session names currently open as tabs (drives the ✓ in the Sessions menu).
    public static var openSessionKeys: Set<String> { Set(manager?.tabs.map(\.sessionKey) ?? []) }

    /// Select a session (loading it if needed), or open the window if none yet.
    public static func focusOrOpen(session name: String) {
        if let m = manager {
            m.selectSession(name)
            m.bringToFront()
        } else {
            newWindow(session: name)
        }
    }

    /// Pushed from the app's `tmux ls` poll so the tab strip lists every session
    /// on the machine (loaded or not).
    public static func setServerSessions(_ names: [String]) {
        manager?.updateServerSessions(names)
    }

    nonisolated static let lastSessionsKey = "mac_last_terminal_sessions"
    /// The strip's stable left-to-right tab order, persisted so it survives
    /// relaunches instead of re-alphabetizing on every cold start.
    nonisolated static let sessionOrderKey = "mac_session_strip_order"
    public nonisolated static let autoHideToolbarFullscreenKey = "auto_hide_toolbar_fullscreen"

    static var autoHideToolbarInFullscreen: Bool {
        UserDefaults.standard.object(forKey: autoHideToolbarFullscreenKey) as? Bool ?? true
    }

    /// Open (or focus) the terminal window — the behavior when the app icon is
    /// clicked. With no window yet, reconnect the session(s) that were open when
    /// it last closed; if there were none, create the default session.
    /// Close the terminal window (sessions keep running on the server; the next
    /// open reconnects them). The red traffic-light button does the same.
    public static func closeMainWindow() { manager?.requestClose() }

    /// Menu-bar command: re-assert the active window's grid on its tmux session
    /// (see GhosttyTiledPaneHost.refitSessionToWindow) — for when another
    /// attached client (an iPad) shrank the shared canvas.
    public static func fitActiveSession() { manager?.activeTab?.paneHost?.refitSessionToWindow() }

    public static func openMainWindow() {
        if let m = manager {
            m.bringToFront()
            return
        }
        let last = (UserDefaults.standard.stringArray(forKey: lastSessionsKey) ?? [])
            .filter { !$0.isEmpty }
        if last.isEmpty {
            newWindow(session: defaultSessionName)
        } else {
            for name in last { newWindow(session: name) }
        }
        manager?.bringToFront()
    }

    static func persistOpenSessions() {
        // Only tmux sessions are reconnectable — plain tabs vanish on close, so
        // they never go into the "reopen last session" list.
        let names = (manager?.tabs ?? []).filter { !$0.isPlain }.map(\.sessionKey)
        UserDefaults.standard.set(names, forKey: lastSessionsKey)
    }

    /// Open a plain shell as a TAB with NO tmux (raw local pty, single surface).
    /// Closing the tab destroys it — there's no session to reconnect.
    public static func newWindowNoTmux() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        ensureManager()
        manager?.openPlainTab()
    }

    /// Drop to a pure menubar (accessory) app when the window is gone.
    static func updateActivationPolicy() {
        if manager == nil { NSApp.setActivationPolicy(.accessory) }
    }

    public static func newWindow(session: String = defaultSessionName) {
        open(choice: .createOrAttach(name: session), title: titleFor(session))
    }

    /// Open a brand-new uniquely-named tmux session as a tab (the tab-bar `+`).
    public static func newSessionTab() {
        let open = openSessionKeys
        var n = max(open.count + 1, 2)
        var name = "session-\(n)"
        while open.contains(name) { n += 1; name = "session-\(n)" }
        newWindow(session: name)
    }

    public static func newWindow(agent spec: AgentSpec) {
        open(choice: .createAgent(spec: spec), title: titleFor(spec.sessionName))
    }

    /// Open a plain (no-tmux) tab running `ssh <host>`, where `host` is an
    /// alias from ~/.ssh/config. Like any plain tab, it's gone when ssh exits
    /// or the tab closes — persistence lives on the remote side, if anywhere.
    public static func newSSHWindow(host: String) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        ensureManager()
        manager?.openSSHTab(host: host)
    }

    private static func ensureManager() {
        if manager == nil {
            let m = TerminalWindowManager()
            m.onEmpty = {
                manager = nil
                // Don't persist here — `manager` is already nil so it would wipe
                // the list to []. The last open/close already recorded the set, so
                // the next open can reconnect it.
                updateActivationPolicy()
            }
            manager = m
        }
    }

    private static func open(choice: TmuxStartChoice, title: String) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        ensureManager()
        manager?.openTab(choice: choice, title: title)
        persistOpenSessions()
    }

    static func titleFor(_ session: String) -> String {
        session == defaultSessionName ? "Bento Terminal" : "Bento · \(session)"
    }
}

// MARK: - SessionTab (a live, self-managed session)

/// One session: its view model, pane host, and lifecycle. Kept alive while it's
/// a background tab — the tmux -CC client keeps streaming so the surfaces stay
/// current; only the active tab's `paneHost` is in the window.
@MainActor
final class SessionTab {
    let viewModel: TerminalViewModel
    /// A tmux tab tiles panes; a plain (no-tmux) tab is a single raw surface.
    /// Exactly one of these is non-nil — `contentView` is whichever the window
    /// should host.
    let paneHost: GhosttyTiledPaneHost?
    let plainSurface: GhosttyTerminalSurface?
    let sessionKey: String
    let choice: TmuxStartChoice
    let windowTitle: String

    /// A plain tab has no tmux behind it: no panes/windows/agents, and closing it
    /// destroys it (it isn't persisted or reconnected).
    var isPlain: Bool { plainSurface != nil }
    var contentView: NSView { paneHost ?? plainSurface! }

    /// `command` overrides the plain tab's login shell (e.g. `["ssh", host]`);
    /// tmux-backed tabs must leave it nil — the VM issues tmux itself.
    init(choice: TmuxStartChoice, title: String, key: String? = nil, command: [String]? = nil) {
        self.choice = choice
        self.windowTitle = title
        self.sessionKey = key ?? Self.key(for: choice)
        let theme = ThemeStore.shared.makeTerminalTheme()
        let storedKey = sessionKey
        let env = TerminalEnvironment(
            idealTerminalSize: { (120, 30) },
            onSessionUpdate: { _, session, awaiting, prompt in
                MacAwaitingNotifier.shared.update(
                    sessionKey: session.isEmpty ? storedKey : session,
                    awaiting: awaiting, prompt: prompt)
            }
        )
        let vm = TerminalViewModel(
            host: Host(name: "Local"),
            transport: LocalPtyTransport(command: command),
            environment: env)
        self.viewModel = vm
        if choice == .noTmux {
            // No tmux → a single raw surface (no tiling host); the VM streams
            // bytes straight to/from it.
            let surface = GhosttyTerminalSurface(theme: theme)
            surface.onInput = { [weak vm] data in vm?.sendData(data) }
            surface.onSizeChanged = { [weak vm] size in
                vm?.resizeTerminal(cols: size.columns, rows: size.rows)
            }
            vm.onRawDataReceived = { [weak surface] data in
                DispatchQueue.main.async { surface?.feed(data) }
            }
            vm.onPredictionText = { [weak surface] text in surface?.setPredictedText(text) }
            self.plainSurface = surface
            self.paneHost = nil
        } else {
            self.paneHost = GhosttyTiledPaneHost(viewModel: vm, theme: theme)
            self.plainSurface = nil
        }
    }

    func connect() {
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.connect()
            await self.viewModel.applyTmuxChoice(self.choice)
        }
    }

    func teardown() {
        paneHost?.teardown()
        plainSurface?.teardown()
        viewModel.disconnect()
        MacAwaitingNotifier.shared.clear(sessionKey: sessionKey)
    }

    static func key(for choice: TmuxStartChoice) -> String {
        switch choice {
        case .createOrAttach(let name): return name
        case .createAgent(let spec): return spec.sessionName
        case .shareWithDesktop(let target): return target
        case .noTmux: return "local"
        }
    }
}

// MARK: - TerminalWindowManager (one window, many session tabs)

@MainActor
final class TerminalWindowManager: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow!
    /// Loaded sessions (a subset of all server sessions). Background ones stay
    /// alive (tmux client streaming) so re-selecting them is instant.
    private(set) var tabs: [SessionTab] = []
    /// Every tmux session on the machine (pushed from the app's `tmux ls` poll),
    /// loaded or not — the tab strip lists ALL of these.
    private var serverSessions: [String] = []
    /// Stable left-to-right order of the strip's segments (persisted). The poll's
    /// activity sort would reshuffle every refresh, so the strip keeps its own
    /// order and only appends newcomers / prunes sessions confirmed gone (see
    /// `reconcileSessionOrder` / `pruneAbsentSessions`).
    private var sessionOrder: [String] = []
    /// Consecutive polls a known session has been missing from `tmux ls`. A single
    /// transient miss must NOT drop it (that reshuffles the strip when it returns),
    /// so pruning waits until it's been gone this many polls.
    private var absentPolls: [String: Int] = [:]
    private static let absentPollsToPrune = 4
    /// The session currently shown (always loaded).
    private var activeKey: String?
    /// The sessions currently shown as segments (subset when overflowing).
    private var visibleSessions: [String] = []

    private let toolbar = TerminalToolbarController()
    /// The window's content is the SYSTEM sidebar arrangement — an
    /// `NSSplitViewController` whose first item is a real sidebar split item.
    /// Material, full-height layout, animated collapse, drag-to-resize, and
    /// width persistence are all AppKit's; we only decide WHEN it shows
    /// (Focus mode) and WHAT it hosts (the shared SwiftUI `WindowSidebar`).
    private let splitVC = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var sidebarHosting: NSHostingController<AnyView>!
    /// Content column root. With `.fullSizeContentView` the column extends
    /// under the toolbar, so the terminal container insets by the safe area —
    /// re-derived on every layout pass (the closure runs `layoutContent`).
    private let contentRoot = LayoutHookView()
    private let container = NSView()
    /// Opaque theme-colored filler under the toolbar band. The unified
    /// toolbar's material samples the content BENEATH it — with the terminal
    /// inset below the safe area, that band would otherwise be undefined
    /// chrome, and the toolbar's frosting could never match the terminal.
    /// Frosting the theme color itself is the system-correct unified look
    /// (what Safari's toolbar does over page content).
    private let topFill = NSView()
    /// The tab the sidebar's rootView was built for (swapped on tab switch).
    private var sidebarHostKey: String?
    /// True when more sessions exist than fit — the last segment becomes a `⋯`
    /// that pops the full list.
    private var hasOverflow = false
    /// Local right-click monitor so a right-click on the tab strip pops the
    /// current session's actions (the power-user path alongside the named button).
    private var rightClickMonitor: Any?

    /// Toolbar bindings to the *active* tab's VM (re-subscribed on switch).
    private var activeCancellables = Set<AnyCancellable>()
    /// Per-tab subscriptions (agent dots + tab titles), keyed by tab identity.
    private var tabCancellables: [ObjectIdentifier: Set<AnyCancellable>] = [:]

    var onEmpty: (() -> Void)?

    override init() {
        super.init()
        // Restore the persisted tab order.
        sessionOrder = UserDefaults.standard.stringArray(forKey: BentoTerminalWindow.sessionOrderKey) ?? []
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.titleVisibility = .hidden
        // Full-size content: the sidebar column runs the window's full height
        // (Finder-style) and the title bar blends into the terminal — the
        // window chrome wears the ghostty theme's background.
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titlebarSeparatorStyle = .none

        // Content = the system sidebar arrangement. The sidebar split item
        // brings the native material, full-height layout, animated collapse,
        // divider drag, and width autosave — no hand-rolled chrome.
        contentRoot.autoresizesSubviews = false
        contentRoot.onLayout = { [weak self] in self?.layoutContent() }
        topFill.wantsLayer = true
        contentRoot.addSubview(topFill)
        contentRoot.addSubview(container)

        sidebarHosting = NSHostingController(rootView: AnyView(EmptyView()))
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 340
        sidebar.allowsFullHeightLayout = true
        sidebar.isCollapsed = true
        sidebarItem = sidebar

        let contentVC = NSViewController()
        contentVC.view = contentRoot
        splitVC.addSplitViewItem(sidebar)
        splitVC.addSplitViewItem(NSSplitViewItem(viewController: contentVC))
        splitVC.splitView.autosaveName = "BentoSidebarSplit"
        win.contentViewController = splitVC
        win.setContentSize(NSSize(width: 980, height: 640))
        applyWindowBackground(to: win)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .terminalThemeChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(surfaceBackgroundChanged(_:)),
            name: .ghosttySurfaceBackgroundChanged, object: nil)

        // Toolbar: Sessions ⌄ | [session tabs] | New ⌄ | ⋯ — center hosts the
        // session tabs (every tmux session, loaded or not) as a Finder-style
        // segmented `NSToolbarItemGroup`.
        toolbar.onSelectSegment = { [weak self] idx in self?.segmentPicked(idx) }
        toolbar.onNewAgent = { BentoTerminalWindow.onNewAgentSession?() }
        toolbar.onNewTerminal = { BentoTerminalWindow.newSessionTab() }
        toolbar.onNewPlainShell = { BentoTerminalWindow.newWindowNoTmux() }
        toolbar.onNewSSHHost = { BentoTerminalWindow.newSSHWindow(host: $0) }
        toolbar.onOpenSettings = { BentoTerminalWindow.onOpenSettings?() }
        toolbar.onSelectWindow = { [weak self] id in self?.activeTab?.viewModel.selectWindow(id) }
        toolbar.onCloseWindow = { [weak self] in self?.activeTab?.viewModel.closeWindow() }
        toolbar.onFitSession = { [weak self] in self?.activeTab?.paneHost?.refitSessionToWindow() }
        toolbar.onSelectMode = { [weak self] mode in self?.requestMode(mode) }
        toolbar.onKillSession = { [weak self] in self?.killActiveSession() }
        toolbar.onDetach = { [weak self] in self?.detachActiveSession() }
        toolbar.onCloseTab = { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.removeTab(tab)   // plain tabs vanish; there's nothing to reconnect
        }
        toolbar.onRenameSession = { [weak self] in self?.presentRenameSheet() }
        toolbar.onMoveTabLeft = { [weak self] in self?.moveActiveSession(by: -1) }
        toolbar.onMoveTabRight = { [weak self] in self?.moveActiveSession(by: 1) }
        win.toolbar = toolbar.makeToolbar()
        win.toolbarStyle = .unified
        win.center()
        self.window = win
        layoutContent()

        // Right-click on the tab strip → current session's actions. Scoped to the
        // toolbar band, in the centered region where the tabs live (so the side
        // buttons keep their own click behavior).
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, self.handleToolbarRightClick(event) else { return event }
            return nil
        }
    }

    /// Returns true (consuming the event) when a right-click lands on the tab
    /// strip and the session menu was shown.
    private func handleToolbarRightClick(_ event: NSEvent) -> Bool {
        guard event.window === window, !tabs.isEmpty else { return false }
        let loc = event.locationInWindow
        // In the titlebar/toolbar band (above the content area)?
        guard loc.y > window.contentLayoutRect.maxY else { return false }
        // Roughly the centered tab-strip region — avoid the side buttons.
        let w = window.frame.width
        guard loc.x > w * 0.26, loc.x < w * 0.74 else { return false }
        toolbar.sessionActionsMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return true
    }

    var activeTab: SessionTab? { tabs.first { $0.sessionKey == activeKey } }

    // MARK: Sidebar (Focus mode's window switcher)

    /// The window chrome wears the terminal's background, so the transparent
    /// title bar and any uncovered chrome read as one surface with the
    /// terminal (the ghostty look). The color of record is what the ENGINE
    /// says it renders (`reportedChromeColor`, from GHOSTTY_ACTION_COLOR_CHANGE
    /// — it reflects the user's own ghostty config and runtime OSC 11); the
    /// configured theme is only the pre-first-report fallback.
    private func applyWindowBackground(to win: NSWindow) {
        let color = reportedChromeColor ?? themeBackgroundColor()
        win.backgroundColor = color
        topFill.layer?.backgroundColor = color.cgColor
    }

    /// Last engine-reported background (nil until a surface's first report).
    private var reportedChromeColor: NSColor?

    private func themeBackgroundColor() -> NSColor {
        // ghostty's EFFECTIVE background from the finalized config — the same
        // source the iOS chrome matches against. It includes the user's own
        // ghostty config files and ghostty's built-in theme default, which the
        // ThemeStore intent value misses (that mismatch was visible chrome).
        if let rgb = GhosttyRuntime.shared.effectiveBackgroundRGB() {
            return NSColor(
                srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255, alpha: 1)
        }
        let bg = ThemeStore.shared.makeTerminalTheme().background
        return NSColor(
            srgbRed: CGFloat((bg >> 16) & 0xff) / 255,
            green: CGFloat((bg >> 8) & 0xff) / 255,
            blue: CGFloat(bg & 0xff) / 255, alpha: 1)
    }

    @objc private func themeChanged() {
        // New theme → stale report; surfaces re-report after the config reload.
        reportedChromeColor = nil
        applyWindowBackground(to: window)
    }

    /// A surface in THIS window reported the background it actually renders —
    /// adopt it for the chrome. (Any pane will do: panes of one session share
    /// a background outside exotic per-pane OSC use.)
    @objc private func surfaceBackgroundChanged(_ note: Notification) {
        guard let view = note.object as? GhosttyTerminalSurface,
              view.window === window,
              let color = view.reportedBackgroundColor else { return }
        reportedChromeColor = color
        applyWindowBackground(to: window)
    }

    /// The sidebar is MODE-driven, never user-toggled: it appears exactly when
    /// the active tab is a tmux session in Focus mode (there it IS the window
    /// management surface) and hides in Parallel / plain tabs.
    private var shouldShowSidebar: Bool {
        guard let tab = activeTab, !tab.isPlain else { return false }
        return tab.viewModel.sessionMode == .list
    }

    /// Create / swap / remove the hosted `WindowSidebar` to match the active
    /// tab and its mode, then re-derive the two content frames. Called on tab
    /// switch, mode change, and the toolbar toggle.
    private func updateSidebar() {
        let showing = shouldShowSidebar
        if showing, let tab = activeTab {
            if sidebarHostKey != tab.sessionKey {
                sidebarHosting.rootView = AnyView(WindowSidebar(viewModel: tab.viewModel))
                sidebarHostKey = tab.sessionKey
            }
        } else if let key = sidebarHostKey, key != activeTab?.sessionKey {
            // The hosted VM's tab is gone (or switched away) — drop the
            // observation so a torn-down VM isn't kept alive by SwiftUI.
            sidebarHosting.rootView = AnyView(EmptyView())
            sidebarHostKey = nil
        }
        if sidebarItem.isCollapsed == showing {
            sidebarItem.animator().isCollapsed = !showing
        }
        layoutContent()
    }

    /// The container fills the content column BELOW the toolbar (full-size
    /// content puts the column under it; the safe area says by how much).
    /// Divider drag / sidebar collapse resize flows into the pane host, which
    /// re-fits the tmux client grid — the same path as a window resize.
    private func layoutContent() {
        let b = contentRoot.bounds
        let top = contentRoot.safeAreaInsets.top
        container.frame = NSRect(x: 0, y: 0, width: b.width, height: max(b.height - top, 0))
        topFill.frame = NSRect(x: 0, y: max(b.height - top, 0), width: b.width, height: top)
    }

    // MARK: Mode switch (Tiled ⇄ List)

    /// The toolbar's Tiled|List segmented control picked `mode`. Mode switches
    /// are lossless and unconfirmed by design, with one exception: flattening a
    /// mixed external structure into List can't be exactly restored, so
    /// `setMode` declines and we warn before forcing.
    private func requestMode(_ mode: TmuxSessionMode) {
        guard let tab = activeTab, !tab.isPlain else { return }
        let vm = tab.viewModel
        Task { [weak self] in
            let switched = await vm.setMode(mode)
            guard !switched, let self else { return }
            let alert = NSAlert()
            alert.messageText = "Switch to Focus mode?"
            alert.informativeText = "This session contains a complex layout created "
                + "outside Bento. Switching will flatten every pane into its own window."
            alert.addButton(withTitle: "Flatten")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: self.window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    Task { await vm.setMode(mode, force: true) }
                } else {
                    // Snap the segmented control back to the real mode.
                    self?.toolbar.setSessionMode(vm.sessionMode)
                }
            }
        }
    }

    /// Close the window (sessions survive on the server). `close()` is direct and
    /// always fires `windowWillClose` — more reliable than the traffic-light path.
    func requestClose() { window.close() }

    func bringToFront() {
        // Agent (LSUIElement) apps that just flipped to `.regular` don't always
        // get key/front on the first `activate`; `orderFrontRegardless` shows the
        // window even while the app is still inactive, so it can't open *behind*
        // whatever the user was using when they clicked the icon.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: Open / select / close

    /// Sessions shown in the strip: the persisted order filtered to those that
    /// currently exist (server poll ∪ loaded). An absent-but-not-yet-pruned session
    /// keeps its slot in `sessionOrder` but drops out of the visible list, so a
    /// transient `tmux ls` miss can't reshuffle the strip.
    private func allSessions() -> [String] {
        let present = presentSet()
        return sessionOrder.filter { present.contains($0) }
    }

    /// Every session that exists right now: the poll's list plus any loaded tab not
    /// yet reflected by the poll (just-created).
    private func presentSet() -> Set<String> {
        var s = Set(serverSessions)
        for t in tabs { s.insert(t.sessionKey) }
        return s
    }

    /// Append brand-new sessions (present but never seen) to the end in a
    /// deterministic slot. Non-destructive — existing tabs never move, and pruning
    /// is poll-driven (`pruneAbsentSessions`), so the order stays put.
    private func reconcileSessionOrder() {
        let newcomers = presentSet().subtracting(Set(sessionOrder)).sorted()
        guard !newcomers.isEmpty else { return }
        sessionOrder.append(contentsOf: newcomers)
        persistSessionOrder()
    }

    /// Poll-driven cleanup: drop sessions absent from `tmux ls` for several
    /// consecutive polls (killed elsewhere, or the machine rebooted). One miss is
    /// tolerated so the order doesn't churn.
    private func pruneAbsentSessions() {
        let present = presentSet()
        for key in sessionOrder {
            if present.contains(key) { absentPolls[key] = 0 }
            else { absentPolls[key, default: 0] += 1 }
        }
        let gone = sessionOrder.filter { (absentPolls[$0] ?? 0) >= Self.absentPollsToPrune }
        guard !gone.isEmpty else { return }
        let goneSet = Set(gone)
        sessionOrder.removeAll { goneSet.contains($0) }
        for k in gone { absentPolls[k] = nil }
        persistSessionOrder()
    }

    private func persistSessionOrder() {
        UserDefaults.standard.set(sessionOrder, forKey: BentoTerminalWindow.sessionOrderKey)
    }

    /// Pushed from the app's `tmux ls` poll — the machine's full session list.
    func updateServerSessions(_ names: [String]) {
        serverSessions = names
        if names.isEmpty && tabs.isEmpty { window.close(); return }
        pruneAbsentSessions()
        rebuildTabBar()
    }

    /// Open/create a specific session (New, agent wizard, reopen). Dedupes.
    func openTab(choice: TmuxStartChoice, title: String) {
        let key = SessionTab.key(for: choice)
        if let existing = tabs.first(where: { $0.sessionKey == key }) {
            show(existing)
        } else {
            show(loadTab(choice: choice, title: title))
        }
        bringToFront()
    }

    /// Open a fresh plain (no-tmux) tab. Not deduped — each is a new terminal —
    /// and never persisted, so closing it is final.
    func openPlainTab() {
        var n = 1
        var key = "Terminal"
        while tabs.contains(where: { $0.sessionKey == key }) { n += 1; key = "Terminal \(n)" }
        let tab = SessionTab(choice: .noTmux, title: key, key: key)
        tabs.append(tab)
        subscribe(tab)
        tab.connect()
        show(tab)
        bringToFront()
    }

    /// Open a plain tab running `ssh <host>` instead of a login shell. Not
    /// deduped either — a second connection to the same host gets a numbered
    /// tab, like a second `ssh` in another terminal.
    func openSSHTab(host: String) {
        var n = 1
        var key = host
        while tabs.contains(where: { $0.sessionKey == key }) { n += 1; key = "\(host) \(n)" }
        let tab = SessionTab(choice: .noTmux, title: key, key: key, command: ["ssh", host])
        tabs.append(tab)
        subscribe(tab)
        tab.connect()
        show(tab)
        bringToFront()
    }

    /// Select a session by name: show it if loaded, else lazily attach it.
    func selectSession(_ name: String) {
        if let tab = tabs.first(where: { $0.sessionKey == name }) {
            show(tab)
        } else {
            show(loadTab(choice: .createOrAttach(name: name), title: BentoTerminalWindow.titleFor(name)))
        }
    }

    private func loadTab(choice: TmuxStartChoice, title: String) -> SessionTab {
        let tab = SessionTab(choice: choice, title: title)
        tabs.append(tab)
        subscribe(tab)
        tab.connect()
        BentoTerminalWindow.persistOpenSessions()
        return tab
    }

    /// Reparent the given (loaded) tab's content view into the window.
    private func show(_ tab: SessionTab) {
        container.subviews.forEach { $0.removeFromSuperview() }
        activeKey = tab.sessionKey
        let content = tab.contentView
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        window.makeFirstResponder(content)
        window.title = tab.viewModel.activeTmuxSessionName ?? tab.windowTitle
        rebindActiveToolbar(tab)
        toolbar.setSessionMode(tab.isPlain ? nil : tab.viewModel.sessionMode)
        updateSidebar()
        rebuildTabBar()
    }

    /// Detach the active session: unload its tab but leave the tmux session
    /// running on the server (it stays in the strip as an unloaded session).
    private func detachActiveSession() {
        guard let tab = activeTab else { return }
        removeTab(tab)
    }

    /// Kill the active tmux session (destroys it) and drop its tab.
    private func killActiveSession() {
        guard let tab = activeTab else { return }
        let name = tab.sessionKey
        // Kill via a one-shot CLI command — reliable and independent of the
        // control connection we're about to tear down. (Sending kill-session
        // through the -CC client and then SIGTERM'ing it races, so the session
        // could survive and the next poll would resurrect it.)
        BentoTerminalWindow.killSessionCLI?(name)
        serverSessions.removeAll { $0 == name }
        sessionOrder.removeAll { $0 == name }
        absentPolls[name] = nil
        persistSessionOrder()
        removeTab(tab)
    }

    /// Tear down a loaded session and move on to a neighbor (loading one if
    /// needed). Closes the window only when no sessions remain anywhere.
    private func removeTab(_ tab: SessionTab) {
        unsubscribe(tab)
        tab.contentView.removeFromSuperview()
        tab.teardown()
        tabs.removeAll { $0 === tab }
        BentoTerminalWindow.persistOpenSessions()
        if activeKey == tab.sessionKey { activeKey = nil }
        // Never auto-re-select the session we just removed — for a kill that would
        // re-create it (createOrAttach), and for a detach it would instantly
        // re-attach. Prefer another open tab, else any other session, else close.
        let remaining = allSessions().filter { $0 != tab.sessionKey }
        if let next = tabs.first?.sessionKey ?? remaining.first {
            selectSession(next)
        } else {
            window.close()
        }
    }

    // MARK: Bindings

    /// Active tab → toolbar (the ⋯ menu's window list targets the active VM).
    private func rebindActiveToolbar(_ tab: SessionTab) {
        activeCancellables.removeAll()
        tab.viewModel.$windows
            .combineLatest(tab.viewModel.$activeWindowID)
            .receive(on: RunLoop.main)
            .sink { [weak self] windows, activeID in
                self?.toolbar.windows = windows
                self?.toolbar.activeWindowID = activeID
            }
            .store(in: &activeCancellables)
        // Mode drives the toolbar's Tiled|List switch and the sidebar (List
        // only). Plain tabs have no mode — the switch hides.
        tab.viewModel.$sessionMode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] mode in
                guard let self, let tab, tab === self.activeTab else { return }
                self.toolbar.setSessionMode(tab.isPlain ? nil : mode)
                self.updateSidebar()
            }
            .store(in: &activeCancellables)
    }

    /// Each tab's agent activity + live session name drive its tab in the strip.
    private func subscribe(_ tab: SessionTab) {
        var bag = Set<AnyCancellable>()
        tab.viewModel.$agentsWorking
            .combineLatest(tab.viewModel.$agentsWaiting,
                           tab.viewModel.$agentsDoneUnseen,
                           tab.viewModel.$activeTmuxSessionName)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.rebuildTabBar() }
            .store(in: &bag)
        tabCancellables[ObjectIdentifier(tab)] = bag
    }

    private func unsubscribe(_ tab: SessionTab) {
        tabCancellables[ObjectIdentifier(tab)] = nil
    }

    private func rebuildTabBar() {
        reconcileSessionOrder()
        let all = allSessions()
        let maxVisible = computeMaxVisible()
        var visible = Array(all.prefix(maxVisible))
        // Keep the active session visible even if it'd land in the overflow.
        if let active = activeKey, !visible.contains(active), all.contains(active), !visible.isEmpty {
            visible[visible.count - 1] = active
        }
        visibleSessions = visible
        hasOverflow = all.count > visible.count

        // One segment per visible session (status dot + name); a trailing `⋯`
        // segment when sessions overflow. `key` is a stable signature of the dot
        // so the controller knows when a dot — not just a title — changed.
        var items: [(title: String, key: String, image: NSImage?)] = visible.map { name in
            let dot = sessionDot(for: name)
            return (name, dot.rawValue, dotImage(for: dot))
        }
        if hasOverflow {
            items.append(("", "more", NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More sessions")))
        }
        let activeIdx = activeKey.flatMap { visible.firstIndex(of: $0) } ?? -1
        toolbar.updateTabs(items, selected: activeIdx)
        // Reorder affordance: whether the active tab has a visible neighbor to swap
        // with on each side.
        toolbar.canMoveTabLeft = activeIdx > 0
        toolbar.canMoveTabRight = activeIdx >= 0 && activeIdx < visibleSessions.count - 1

        if let active = activeTab {
            let name = active.viewModel.activeTmuxSessionName ?? active.windowTitle
            window.title = name
            toolbar.setSessionTitle(name)
            toolbar.activeTabIsPlain = active.isPlain
        }
    }

    /// Swap the active tab with its visible neighbor `delta` slots away (−1 left,
    /// +1 right) in the persisted order — the right-click "Move Tab Left/Right"
    /// reorder, since the native segmented strip can't be dragged.
    private func moveActiveSession(by delta: Int) {
        guard let key = activeKey,
              let visIdx = visibleSessions.firstIndex(of: key) else { return }
        let target = visIdx + delta
        guard visibleSessions.indices.contains(target) else { return }
        let neighbor = visibleSessions[target]
        guard let a = sessionOrder.firstIndex(of: key),
              let b = sessionOrder.firstIndex(of: neighbor) else { return }
        sessionOrder.swapAt(a, b)
        persistSessionOrder()
        rebuildTabBar()
    }

    /// Map a visible-segment index to an action: the trailing `⋯` pops the full
    /// session list; any other segment selects that session.
    private func segmentPicked(_ idx: Int) {
        if hasOverflow && idx == visibleSessions.count {
            // Pop the overflow list at the cursor, then restore the selection
            // (the `⋯` segment must not stay highlighted).
            overflowMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            rebuildTabBar()
        } else if visibleSessions.indices.contains(idx) {
            selectSession(visibleSessions[idx])
        }
    }

    private enum DotStyle { case filled, ring }

    /// A small status glyph for a segment: a filled disc (live) or a hollow ring
    /// (dormant). Drawn in the window's effective appearance so semantic
    /// label-color (neutral) glyphs resolve to the right light/dark shade.
    private func dotImage(_ color: NSColor, style: DotStyle, diameter d: CGFloat = 7) -> NSImage {
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            switch style {
            case .filled:
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: d, height: d)).fill()
            case .ring:
                let lw: CGFloat = 1.2
                color.setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: lw / 2, y: lw / 2,
                                                       width: d - lw, height: d - lw))
                ring.lineWidth = lw
                ring.stroke()
            }
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    /// The status of a session segment. Two independent dimensions:
    ///   • shape — filled = open as a tab in Bento, hollow ring = exists on the
    ///     machine but not opened here (dormant). This is OUR own connection
    ///     state, not tmux's `session_attached` (which also counts Terminal.app /
    ///     iPhone clients and lags behind the poll).
    ///   • color (filled only) — agent activity, highest priority first:
    ///     awaiting (yellow) → done-unseen (blue) → working (green) → idle (gray).
    private enum SessionDot: String { case awaiting, doneUnseen, working, idle, dormant, plain }

    private func sessionDot(for name: String) -> SessionDot {
        guard let tab = tabs.first(where: { $0.sessionKey == name }) else {
            return .dormant   // not open in Bento → hollow ring
        }
        if tab.isPlain { return .plain }   // no tmux → a terminal glyph, not a dot
        let vm = tab.viewModel
        if vm.agentsWaiting > 0    { return .awaiting }
        if vm.agentsDoneUnseen > 0 { return .doneUnseen }
        if vm.agentsWorking > 0    { return .working }
        return .idle           // open, no agent activity → filled gray
    }

    /// Render a session-dot. Neutral grays use semantic label colors so they
    /// adapt to light/dark; the agent colors are fixed.
    private func dotImage(for dot: SessionDot) -> NSImage {
        switch dot {
        case .awaiting:   return dotImage(PaneState.awaitingInput(profile: "").nsColor, style: .filled) // yellow
        case .doneUnseen: return dotImage(PaneTitleBar.doneColor, style: .filled)                       // blue
        case .working:    return dotImage(PaneState.working.nsColor, style: .filled)                    // green
        case .idle:       return dotImage(.secondaryLabelColor, style: .filled)                         // attached, idle
        case .dormant:    return dotImage(.tertiaryLabelColor, style: .ring)                            // not attached
        case .plain:      return glyphImage("apple.terminal")                                           // no-tmux terminal
        }
    }

    /// A small SF Symbol used in place of the status dot (e.g. the plain-terminal
    /// tab's terminal glyph), tinted to the label color and appearance-resolved.
    private func glyphImage(_ symbol: String) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Terminal")?
            .withSymbolConfiguration(cfg) ?? NSImage()
        let img = NSImage(size: base.size)
        img.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.secondaryLabelColor.set()
            base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    /// How many segments fit before overflowing, from the window width.
    private func computeMaxVisible() -> Int {
        let budget = max(220, window.frame.width - 540)
        return max(1, Int(budget / 110))
    }

    /// The overflow `⋯` menu — every session, the active one checkmarked.
    private func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        for name in allSessions() {
            let item = NSMenuItem(title: name, action: #selector(overflowPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = (name == activeKey) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func overflowPicked(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { selectSession(name) }
    }

    private func presentRenameSheet() {
        guard let tab = activeTab else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.viewModel.activeTmuxSessionName ?? ""
        field.placeholderString = "session name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            tab.viewModel.renameSession(to: field.stringValue)
        }
    }

    // MARK: NSWindowDelegate

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        BentoTerminalWindow.autoHideToolbarInFullscreen
            ? proposedOptions.union(.autoHideToolbar)
            : proposedOptions
    }

    func windowWillClose(_ notification: Notification) {
        // Free every session's surfaces BEFORE AppKit tears the window down.
        if let m = rightClickMonitor { NSEvent.removeMonitor(m); rightClickMonitor = nil }
        activeCancellables.removeAll()
        tabCancellables.removeAll()
        // Drop the sidebar's SwiftUI observation before the VMs are torn down.
        sidebarHosting.rootView = AnyView(EmptyView())
        sidebarHostKey = nil
        for tab in tabs {
            tab.contentView.removeFromSuperview()
            tab.teardown()
        }
        tabs.removeAll()
        window.toolbar = nil
        window.delegate = nil
        onEmpty?()
    }
}

/// A plain view that reports layout passes — the content column uses it to
/// re-inset the terminal container by the (toolbar) safe area whenever the
/// split view or window reshapes it.
private final class LayoutHookView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}
#endif
