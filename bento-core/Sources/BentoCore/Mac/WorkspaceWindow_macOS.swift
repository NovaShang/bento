#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI

/// The one Bento workspace window: session tabs run on the shared agent
/// workspace store. macOS uses the *same* runtime stack as iOS; only the
/// daemon link differs (local unix socket vs relay).
///
/// Sessions are SELF-MANAGED tabs (not native macOS window tabs): a single
/// `WorkspaceWindowManager` hosts one NSWindow whose toolbar center holds a
/// Finder-style segmented `NSToolbarItemGroup`. Each tab is a live `SessionTab`
/// (its view model + panes stay alive in the background); switching just
/// reparents the active tab's pane host into the window, so switches are
/// instant and state-preserving.
@MainActor
public enum WorkspaceWindow {
    private static var manager: WorkspaceWindowManager?

    /// The session created when the window opens with no previous session.
    /// User-configurable (Settings → Sessions); defaults to the app name.
    public nonisolated static let defaultSessionNameKey = "default_session_name"
    private nonisolated static let fallbackDefaultSessionName = "bento"
    public nonisolated static var defaultSessionName: String {
        let raw = UserDefaults.standard.string(forKey: defaultSessionNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return fallbackDefaultSessionName }
        return raw.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    /// App-provided hooks for toolbar actions that live in the app target.
    public static var onNewAgentSession: (() -> Void)?
    public static var onOpenSettings: (() -> Void)?
    public static var sessionsMenuProvider: (() -> NSMenu?)?

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

    /// Pushed from the app's session poll so the tab strip lists every session
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

    /// Close the workspace window (sessions keep running in the daemon; the
    /// next open reconnects them). The red traffic-light button does the same.
    public static func closeMainWindow() { manager?.requestClose() }

    /// ⌘P: open the command palette over the focused window's active pane.
    public static func presentCommandPalette() { manager?.activeTab?.paneHost.presentCommandPalette() }

    /// Open a file preview in the focused window's side dock (the default
    /// surface — ⌘click, palette, context menu all land here).
    static func openPreview(path: String, line: Int?, context: PathPreviewContext) {
        manager?.openPreview(path: path, line: line, context: context)
    }

    /// Show/hide the preview dock (pins survive a hide). ⌥⌘P and the palette.
    public static func togglePreviewDock() { manager?.togglePreviewDock() }

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
        let names = (manager?.tabs ?? []).map(\.sessionKey)
        UserDefaults.standard.set(names, forKey: lastSessionsKey)
    }

    /// Drop to a pure menubar (accessory) app when the window is gone.
    static func updateActivationPolicy() {
        if manager == nil { NSApp.setActivationPolicy(.accessory) }
    }

    public static func newWindow(session: String = defaultSessionName) {
        open(choice: .createOrAttach(name: session), title: titleFor(session))
    }

    /// Open a brand-new uniquely-named workspace session as a tab (the tab-bar `+`).
    public static func newSessionTab() {
        let open = openSessionKeys
        var n = max(open.count + 1, 2)
        var name = "workspace-\(n)"
        while open.contains(name) { n += 1; name = "workspace-\(n)" }
        newWindow(session: name)
    }

    public static func newWindow(agent spec: AgentSpec) {
        open(choice: .createAgent(spec: spec), title: titleFor(spec.workspaceName))
    }

    private static func ensureManager() {
        if manager == nil {
            let m = WorkspaceWindowManager()
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

    private static func open(choice: SessionStartChoice, title: String) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        ensureManager()
        manager?.openTab(choice: choice, title: title)
        persistOpenSessions()
    }

    static func titleFor(_ session: String) -> String {
        session == defaultSessionName ? "Bento" : "Bento · \(session)"
    }
}

// MARK: - SessionTab (a live, self-managed session)

/// One session: its view model, pane host, and lifecycle. Kept alive while it's
/// a background tab — the store keeps streaming so the panes stay
/// current; only the active tab's `paneHost` is in the window.
@MainActor
final class SessionTab {
    let viewModel: WorkspaceViewModel
    let paneHost: TiledPaneHost
    /// The session's identity everywhere (strip order, active selection,
    /// persistence, the kill target). A session rename changes that identity,
    /// so the manager migrates this key to follow (`migrateSessionKey`).
    fileprivate(set) var sessionKey: String
    let choice: SessionStartChoice
    let windowTitle: String

    var contentView: NSView { paneHost }

    /// The focused pane's file context — what the dock's directory tree
    /// roots itself at.
    var previewContext: PathPreviewContext? {
        paneHost.activePathPreviewContext
    }

    init(choice: SessionStartChoice, title: String, key: String? = nil) {
        self.choice = choice
        self.windowTitle = title
        self.sessionKey = key ?? Self.key(for: choice)
        let theme = ThemeStore.shared.makeCanvasTheme()
        let storedKey = sessionKey
        let env = WorkspaceEnvironment(
            onSessionUpdate: { _, session, awaiting, prompt in
                MacAwaitingNotifier.shared.update(
                    sessionKey: session.isEmpty ? storedKey : session,
                    awaiting: awaiting, prompt: prompt)
            }
        )
        let vm = WorkspaceViewModel(
            host: Host(name: "Local"),
            workspace: .shared,
            environment: env)
        self.viewModel = vm
        self.paneHost = TiledPaneHost(viewModel: vm, theme: theme)
    }

    func connect() {
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.start(self.choice)
        }
    }

    func teardown() {
        paneHost.teardown()
        viewModel.disconnect()
        MacAwaitingNotifier.shared.clear(sessionKey: sessionKey)
    }

    static func key(for choice: SessionStartChoice) -> String {
        switch choice {
        case .createOrAttach(let name): return name
        case .createAgent(let spec): return spec.workspaceName
        }
    }
}

// MARK: - WorkspaceWindowManager (one window, many session tabs)

@MainActor
final class WorkspaceWindowManager: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow!
    /// Loaded sessions (a subset of all server sessions). Background ones stay
    /// alive (store streaming) so re-selecting them is instant.
    private(set) var tabs: [SessionTab] = []
    /// Every workspace session on the machine (pushed from the app's session poll),
    /// loaded or not — the tab strip lists ALL of these.
    private var serverSessions: [String] = []
    /// Stable left-to-right order of the strip's segments (persisted). The poll's
    /// activity sort would reshuffle every refresh, so the strip keeps its own
    /// order and only appends newcomers / prunes sessions confirmed gone (see
    /// `reconcileSessionOrder` / `pruneAbsentSessions`).
    private var sessionOrder: [String] = []
    /// Consecutive polls a known session has been missing from the session poll. A single
    /// transient miss must NOT drop it (that reshuffles the strip when it returns),
    /// so pruning waits until it's been gone this many polls.
    private var absentPolls: [String: Int] = [:]
    private static let absentPollsToPrune = 4
    /// Sessions the user just killed here, awaiting confirmation from the poll.
    /// `killSessionCLI` kills asynchronously, so a poll firing
    /// in the gap still sees the doomed session — without this, `reconcileSessionOrder`
    /// would re-add it as a "newcomer" and it would linger ~20s (BUG-016). Cleared
    /// once the poll confirms it's actually gone.
    private var killedSessions: Set<String> = []
    /// The session currently shown (always loaded).
    private var activeKey: String?
    /// The sessions currently shown as segments (subset when overflowing).
    private var visibleSessions: [String] = []

    private let toolbar = WorkspaceToolbar()
    /// Workspace switcher shown at the top of the Focus sidebar (the workspace
    /// button moves there in Focus). Refreshed from `rebuildTabBar`; its actions
    /// are wired in `init`.
    private let workspaceSwitcher = WorkspaceSwitcherModel()
    /// The window's content is the SYSTEM sidebar arrangement — an
    /// `NSSplitViewController` whose first item is a real sidebar split item.
    /// Material, full-height layout, animated collapse, drag-to-resize, and
    /// width persistence are all AppKit's; we only decide WHEN it shows
    /// (Focus mode) and WHAT it hosts (the shared SwiftUI `PaneSidebar`).
    private let splitVC = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var sidebarHosting: NSHostingController<AnyView>!
    /// Trailing "pin previews here" dock — a collapsed split item that expands
    /// on the first pin. One model per window, persists across tab switches.
    let previewDock = PreviewDockModel()
    private var dockItem: NSSplitViewItem!
    /// True only while the dock is showing because WE auto-opened it to soak a
    /// fullscreen-wide Focus pane's spare width — so a later resize (or leaving
    /// Focus) knows it may undo that. Any user toggle or file pin clears it: the
    /// dock is theirs then, and we never yank it out from under them.
    private var dockAutoOpened = false
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
        sessionOrder = UserDefaults.standard.stringArray(forKey: WorkspaceWindow.sessionOrderKey) ?? []
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.titleVisibility = .hidden
        // Full-size content: the sidebar column runs the window's full height
        // (Finder-style) and the title bar blends into the panes — the
        // window chrome wears the theme's canvas background.
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

        // Trailing preview dock: collapsed until something is pinned. The
        // dock's content starts BELOW the title bar (safe-area top) — unlike
        // the full-height sidebar, it reads as a panel UNDER the window
        // chrome, not a column through it.
        let dockVC = NSViewController()
        let dockRoot = NSView()
        let dockHosting = NSHostingView(rootView: PreviewDock(model: previewDock))
        dockHosting.translatesAutoresizingMaskIntoConstraints = false
        dockRoot.addSubview(dockHosting)
        NSLayoutConstraint.activate([
            dockHosting.topAnchor.constraint(equalTo: dockRoot.safeAreaLayoutGuide.topAnchor),
            dockHosting.leadingAnchor.constraint(equalTo: dockRoot.leadingAnchor),
            dockHosting.trailingAnchor.constraint(equalTo: dockRoot.trailingAnchor),
            dockHosting.bottomAnchor.constraint(equalTo: dockRoot.bottomAnchor),
        ])
        dockVC.view = dockRoot
        let dock = NSSplitViewItem(viewController: dockVC)
        dock.canCollapse = true
        dock.minimumThickness = 300
        dock.maximumThickness = 720
        dock.isCollapsed = true
        dock.holdingPriority = NSLayoutConstraint.Priority(251)  // terminal flexes, dock holds
        dockItem = dock
        splitVC.addSplitViewItem(dock)
        // Inspector-style toolbar toggle (always present). The dock's first
        // tab is the focused pane's directory tree; the provider resolves the
        // CURRENT pane at load time, so the tree follows the user.
        toolbar.onTogglePreview = { [weak self] in self?.togglePreviewDock() }
        previewDock.treeContextProvider = { [weak self] in self?.activeTab?.previewContext }

        splitVC.splitView.autosaveName = "BentoSidebarSplit"
        win.contentViewController = splitVC
        win.setContentSize(NSSize(width: 980, height: 640))
        // The splitView autosave (kept for the sidebar width) also remembers
        // the dock's expanded state across window incarnations — a fresh
        // window would restore yesterday's EXPANDED dock with a brand-new,
        // empty, uncloseable model behind it. Dock visibility is model-driven
        // only: re-assert emptiness after the restoration that the
        // contentViewController assignment just applied (and once more next
        // runloop turn, in case restoration lands on first display).
        dockItem.isCollapsed = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dockItem.isCollapsed = self.previewDock.tabs.isEmpty
        }
        applyWindowBackground(to: win)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .terminalThemeChanged, object: nil)

        // Toolbar: Sessions ⌄ | [session tabs] | New ⌄ | ⋯ — center hosts the
        // session tabs (every workspace session, loaded or not) as a Finder-style
        // segmented `NSToolbarItemGroup`.
        toolbar.onSelectSegment = { [weak self] idx in self?.segmentPicked(idx) }
        toolbar.onNewAgent = { WorkspaceWindow.onNewAgentSession?() }
        toolbar.onNewTerminal = { WorkspaceWindow.newSessionTab() }
        toolbar.onOpenSettings = { WorkspaceWindow.onOpenSettings?() }
        toolbar.onSelectPane = { [weak self] id in self?.activeTab?.viewModel.selectPane(id) }
        toolbar.onSelectMode = { [weak self] mode in self?.setMode(mode) }
        toolbar.onKillSession = { [weak self] in self?.killActiveSession() }
        toolbar.onDetach = { [weak self] in self?.detachActiveSession() }
        toolbar.onRenameSession = { [weak self] in self?.presentRenameSheet() }
        toolbar.onShowHistory = { [weak self] in self?.presentHistoryPanel() }
        toolbar.onMoveTabLeft = { [weak self] in self?.moveActiveSession(by: -1) }
        toolbar.onMoveTabRight = { [weak self] in self?.moveActiveSession(by: 1) }
        // The sidebar workspace switcher (Focus) drives the same actions the
        // Parallel toolbar does — relocated to where workspace nav belongs in Focus.
        workspaceSwitcher.onSwitch = { [weak self] name in self?.selectSession(name) }
        workspaceSwitcher.onNewWorkspace = { WorkspaceWindow.onNewAgentSession?() }
        workspaceSwitcher.onRename = { [weak self] in self?.presentRenameSheet() }
        workspaceSwitcher.onDetach = { [weak self] in self?.detachActiveSession() }
        workspaceSwitcher.onKill = { [weak self] in self?.killActiveSession() }
        // Agent-level New (Focus). The active pane is the focused agent, so no
        // pane pre-selection is needed.
        toolbar.onNewChat = { [weak self] in self?.agentNewChat() }
        toolbar.onNewAgentPane = { [weak self] in self?.agentNewPane() }
        win.toolbar = toolbar.makeToolbar()
        win.toolbarStyle = .unified
        // Remember the window's size + position across launches (AppKit persists
        // the frame to UserDefaults on every move/resize under this name). Only
        // center on the very first launch, when there's no saved frame — otherwise
        // the window reopened small and centered every time.
        win.setFrameAutosaveName("BentoMainTerminalWindow")
        if !win.setFrameUsingName("BentoMainTerminalWindow") {
            win.center()
        }
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

    /// Open a preview in the side dock (expanding it) and bring the window front.
    /// The split animation stays cheap because `AgentChatSurface` freezes each
    /// pane's transcript width for the animation's duration (one reflow at the
    /// end, not one per frame) — see its resize-coalescing.
    func openPreview(path: String, line: Int?, context: PathPreviewContext) {
        previewDock.open(path: path, line: line, context: context)
        dockItem?.animator().isCollapsed = false
        dockAutoOpened = false   // holds a user pin now — never auto-close it
        window?.makeKeyAndOrderFront(nil)
    }

    /// Show/hide the dock without touching its tabs.
    func togglePreviewDock() {
        dockItem.animator().isCollapsed.toggle()
        dockAutoOpened = false   // the user owns the dock's visibility now
    }

    /// In Focus mode a fullscreen-wide window caps the transcript column at its
    /// readable max (`AcpChatLayout.maxReadableWidth`) and leaves spare gutter.
    /// Rather than waste it, auto-open the preview dock (its file tree) to fill
    /// the width; when the room's gone — the window shrank, or we left Focus —
    /// undo that. We only ever touch a dock WE opened (`dockAutoOpened`): one the
    /// user toggled or pinned a file into is left exactly as they left it.
    private func updateAutoDock() {
        guard window != nil, dockItem != nil else { return }
        let focusMode = activeTab?.viewModel.workspaceMode == .list

        // The width the transcript would get with the dock CLOSED — the decision
        // input, framed so it DOESN'T shift when the dock itself opens/closes
        // (else the two chase each other). `contentRoot` is the middle column;
        // add the dock's own width back when it's currently expanded.
        let dockWidth = dockItem.isCollapsed ? 0 : dockItem.viewController.view.frame.width
        let paneIfDockClosed = contentRoot.bounds.width + dockWidth

        // Hysteresis: open only when a full-min dock fits ALONGSIDE a full-width
        // readable transcript; close a little sooner so the pair can't flap at
        // the boundary.
        let openAt = AcpChatLayout.maxReadableWidth + dockItem.minimumThickness
        let closeAt = AcpChatLayout.maxReadableWidth + dockItem.minimumThickness * 0.66

        if focusMode, dockItem.isCollapsed, paneIfDockClosed >= openAt {
            dockItem.animator().isCollapsed = false
            dockAutoOpened = true
        } else if dockAutoOpened, previewDock.tabs.isEmpty,
                  !focusMode || paneIfDockClosed < closeAt {
            dockItem.animator().isCollapsed = true
            dockAutoOpened = false
        }
    }

    // MARK: Sidebar (Focus mode's window switcher)

    /// The window chrome wears the theme's canvas background, so the
    /// transparent title bar and any uncovered chrome read as one surface
    /// with the panes.
    private func applyWindowBackground(to win: NSWindow) {
        let color = themeBackgroundColor()
        win.backgroundColor = color
        topFill.layer?.backgroundColor = color.cgColor
    }

    private func themeBackgroundColor() -> NSColor {
        // The CURRENT effective theme's background — it follows
        // appearanceMode / systemIsDark LIVE.
        let bg = ThemeStore.shared.current.bg
        return NSColor(
            srgbRed: CGFloat((bg >> 16) & 0xff) / 255,
            green: CGFloat((bg >> 8) & 0xff) / 255,
            blue: CGFloat(bg & 0xff) / 255, alpha: 1)
    }

    @objc private func themeChanged() {
        applyWindowBackground(to: window)
    }

    /// The sidebar is MODE-driven, never user-toggled: it appears exactly when
    /// the active tab is in Focus mode (there it IS the pane management
    /// surface) and hides in Parallel.
    private var shouldShowSidebar: Bool {
        guard let tab = activeTab else { return false }
        return tab.viewModel.workspaceMode == .list
    }

    /// Create / swap / remove the hosted `PaneSidebar` to match the active
    /// tab and its mode, then re-derive the two content frames. Called on tab
    /// switch, mode change, and the toolbar toggle.
    private func updateSidebar() {
        let showing = shouldShowSidebar
        if showing, let tab = activeTab {
            if sidebarHostKey != tab.sessionKey {
                sidebarHosting.rootView = AnyView(
                    PaneSidebar(viewModel: tab.viewModel, switcher: workspaceSwitcher))
                sidebarHostKey = tab.sessionKey
            }
        } else if let key = sidebarHostKey, key != activeTab?.sessionKey {
            // The hosted VM's tab is gone (or switched away) — drop the
            // observation so a torn-down VM isn't kept alive by SwiftUI.
            sidebarHosting.rootView = AnyView(EmptyView())
            sidebarHostKey = nil
        }
        if sidebarItem.isCollapsed == showing {
            // Animated: the focused pane's transcript is frozen at its current
            // width for the animation (AgentChatSurface resize-coalescing), so
            // the divider slide costs one reflow at the end, not one per frame.
            sidebarItem.animator().isCollapsed = !showing
        }
        layoutContent()
        // Mode/tab changes flip Focus on and off and reshape the pane — re-decide
        // whether the dock should soak the spare width.
        updateAutoDock()
    }

    /// The container fills the content column BELOW the toolbar (full-size
    /// content puts the column under it; the safe area says by how much).
    /// Divider drag / sidebar collapse resize flows into the pane host, which
    /// re-fits the session canvas grid — the same path as a window resize.
    private func layoutContent() {
        let b = contentRoot.bounds
        let top = contentRoot.safeAreaInsets.top
        container.frame = NSRect(x: 0, y: 0, width: b.width, height: max(b.height - top, 0))
        topFill.frame = NSRect(x: 0, y: max(b.height - top, 0), width: b.width, height: top)
    }

    // MARK: Mode switch (Tiled ⇄ List)

    /// The toolbar's Tiled|List segmented control picked `mode`. Mode switches
    /// are lossless and unconfirmed — a pure view-preference toggle.
    private func setMode(_ mode: WorkspaceViewMode) {
        activeTab?.viewModel.setMode(mode)
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
    /// transient session-poll miss can't reshuffle the strip.
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
        let newcomers = presentSet()
            .subtracting(Set(sessionOrder))
            .subtracting(killedSessions)   // don't resurrect a session mid-kill
            .sorted()
        guard !newcomers.isEmpty else { return }
        sessionOrder.append(contentsOf: newcomers)
        persistSessionOrder()
    }

    /// Poll-driven cleanup: drop sessions absent from the session poll for several
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
        UserDefaults.standard.set(sessionOrder, forKey: WorkspaceWindow.sessionOrderKey)
    }

    /// Pushed from the app's session poll — the machine's full session list.
    func updateServerSessions(_ names: [String]) {
        serverSessions = names
        // A killed session stays tombstoned only until the poll stops reporting
        // it (kill landed). Lifting it here — when it's already absent — means a
        // later, legitimately re-created session of the same name isn't suppressed.
        killedSessions.formIntersection(names)
        if names.isEmpty && tabs.isEmpty { window.close(); return }
        pruneAbsentSessions()
        rebuildTabBar()
    }

    /// Open/create a specific session (New, agent wizard, reopen). Dedupes.
    func openTab(choice: SessionStartChoice, title: String) {
        let key = SessionTab.key(for: choice)
        if let existing = tabs.first(where: { $0.sessionKey == key }) {
            show(existing)
        } else {
            show(loadTab(choice: choice, title: title))
        }
        bringToFront()
    }

    /// Select a session by name: show it if loaded, else lazily attach it.
    func selectSession(_ name: String) {
        if let tab = tabs.first(where: { $0.sessionKey == name }) {
            show(tab)
        } else {
            show(loadTab(choice: .createOrAttach(name: name), title: WorkspaceWindow.titleFor(name)))
        }
    }

    private func loadTab(choice: SessionStartChoice, title: String) -> SessionTab {
        let tab = SessionTab(choice: choice, title: title)
        tabs.append(tab)
        subscribe(tab)
        tab.connect()
        WorkspaceWindow.persistOpenSessions()
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
        window.title = tab.viewModel.activeWorkspaceName ?? tab.windowTitle
        rebindActiveToolbar(tab)
        toolbar.setSessionMode(tab.viewModel.workspaceMode)
        updateSidebar()
        rebuildTabBar()
    }

    /// Detach the active session: unload its tab but leave the workspace session
    /// running on the server (it stays in the strip as an unloaded session).
    private func detachActiveSession() {
        guard let tab = activeTab else { return }
        removeTab(tab)
    }

    /// Kill the active workspace session (destroys it) and drop its tab.
    private func killActiveSession() {
        guard let tab = activeTab, let window else { return }
        let name = tab.sessionKey
        // Kill Session is destructive AND irreversible — every window/pane and
        // its running processes die. Confirm first (parity with iOS) so a stray
        // click doesn't silently end a session with work in it.
        let alert = NSAlert()
        alert.messageText = "Kill workspace “\(name)”?"
        alert.informativeText = "Every pane in this workspace is closed and its running processes are terminated. This can’t be undone."
        alert.alertStyle = .warning
        let killButton = alert.addButton(withTitle: "Kill Workspace")
        alert.addButton(withTitle: "Cancel")
        killButton.keyEquivalent = ""   // require a deliberate click, not Return
        if #available(macOS 11.0, *) { killButton.hasDestructiveAction = true }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performKillSession(tab: tab, name: name)
        }
    }

    private func performKillSession(tab: SessionTab, name: String) {
        // The store kills the agents and removes the session; the change
        // mirrors to the daemon's statekv so other devices converge.
        AgentWorkspaceStore.shared.killSession(name)
        // Tombstone it: a session poll firing before the mirror lands would
        // otherwise re-add this session to the strip (BUG-016).
        killedSessions.insert(name)
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
        WorkspaceWindow.persistOpenSessions()
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

    /// Active tab → toolbar (the ⋯ menu's pane list targets the active VM).
    private func rebindActiveToolbar(_ tab: SessionTab) {
        activeCancellables.removeAll()
        tab.viewModel.$sessionPanes
            .combineLatest(tab.viewModel.$activePaneID)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] panes, activeID in
                guard let tab else { return }
                self?.toolbar.panes = panes.map { ($0.id, tab.viewModel.paneDisplayName($0.id)) }
                self?.toolbar.activePaneID = activeID
                self?.updateToolbarAgent()   // Focus left button follows the active agent
            }
            .store(in: &activeCancellables)
        // Mode drives the toolbar's Tiled|List switch and the sidebar (List
        // only).
        tab.viewModel.$workspaceMode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] mode in
                guard let self, let tab, tab === self.activeTab else { return }
                self.toolbar.setSessionMode(mode)
                self.updateToolbarAgent()
                // Re-fill the tab strip: setSessionMode re-inserts the centered
                // tabs group when returning to Parallel, so refresh its contents
                // now instead of waiting for the next poll (also keeps the sidebar
                // switcher current on the flip into Focus).
                self.rebuildTabBar()
                self.updateSidebar()
            }
            .store(in: &activeCancellables)
        // The dock's directory tree follows the FOCUSED pane: switching window
        // (⌘1..9) or selecting another tiled pane changes activePaneID, so
        // re-root the tree on it (fires immediately for the newly-active tab
        // too — its initial value seeds the first load).
        tab.viewModel.$activePaneID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.previewDock.refreshTree()
            }
            .store(in: &activeCancellables)
    }

    /// Each tab's agent activity + live session name drive its tab in the strip.
    private func subscribe(_ tab: SessionTab) {
        var bag = Set<AnyCancellable>()
        tab.viewModel.$agentsWorking
            .combineLatest(tab.viewModel.$agentsWaiting,
                           tab.viewModel.$agentsDoneUnseen,
                           tab.viewModel.$activeWorkspaceName)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _, _, _, name in
                guard let self else { return }
                if let tab, let name { self.migrateSessionKey(of: tab, to: name) }
                self.rebuildTabBar()
            }
            .store(in: &bag)
        tabCancellables[ObjectIdentifier(tab)] = bag
    }

    private func unsubscribe(_ tab: SessionTab) {
        tabCancellables[ObjectIdentifier(tab)] = nil
    }

    /// A session rename — ours or another device's — changes
    /// the session's identity, and `sessionKey` IS that identity everywhere:
    /// the strip order, the active selection, persistence, and the kill CLI
    /// target. The key must follow, or the old name haunts the strip forever
    /// (the loaded tab keeps it "present" past every prune) while the new name
    /// shows up as a phantom dormant session — and Kill Session silently kills
    /// a name that no longer exists.
    private func migrateSessionKey(of tab: SessionTab, to name: String) {
        let old = tab.sessionKey
        guard !name.isEmpty, name != old,
              !tabs.contains(where: { $0 !== tab && $0.sessionKey == name }) else { return }
        tab.sessionKey = name
        // The poll may already list the new name (appended as a "newcomer"
        // segment) — collapse it into the old slot instead of keeping both.
        sessionOrder.removeAll { $0 == name }
        if let idx = sessionOrder.firstIndex(of: old) { sessionOrder[idx] = name }
        // Drop the old name from a not-yet-refreshed poll snapshot so the next
        // reconcile doesn't resurrect it as a newcomer.
        serverSessions.removeAll { $0 == old }
        absentPolls[name] = absentPolls.removeValue(forKey: old)
        if activeKey == old { activeKey = name }
        persistSessionOrder()
        WorkspaceWindow.persistOpenSessions()
        MacAwaitingNotifier.shared.clear(sessionKey: old)
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
            items.append(("", "more", NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More workspaces")))
        }
        let activeIdx = activeKey.flatMap { visible.firstIndex(of: $0) } ?? -1
        toolbar.updateTabs(items, selected: activeIdx)
        // Reorder affordance: whether the active tab has a visible neighbor to swap
        // with on each side.
        toolbar.canMoveTabLeft = activeIdx > 0
        toolbar.canMoveTabRight = activeIdx >= 0 && activeIdx < visibleSessions.count - 1

        // Feed the full workspace set to the sidebar switcher (all of them, not
        // just the visible strip — its menu scrolls).
        workspaceSwitcher.workspaces = all.map {
            .init(name: $0, isCurrent: $0 == activeKey, isDormant: sessionDot(for: $0) == .dormant)
        }

        if let active = activeTab {
            let name = active.viewModel.activeWorkspaceName ?? active.windowTitle
            window.title = name
            toolbar.setSessionTitle(name)
            workspaceSwitcher.currentName = name
        }
        // Agent activity changed (this runs on the aggregate-state publishes),
        // so refresh the Focus centered agent title's state glyph too.
        updateToolbarAgent()
    }

    // MARK: Agent-level toolbar (Focus)

    /// Push the active pane's name + state onto the toolbar's centered Focus title.
    private func updateToolbarAgent() {
        guard let tab = activeTab, let id = tab.viewModel.activePaneID else {
            toolbar.setActiveAgent(name: "Agent", status: .idle)
            return
        }
        toolbar.setActiveAgent(name: tab.viewModel.paneDisplayName(id),
                               status: tab.viewModel.paneStatus(id))
    }

    /// New Chat: drop the active pane's conversation (it lives on in history) and
    /// spawn a fresh agent in the same pane.
    private func agentNewChat() {
        guard let tab = activeTab, let id = tab.viewModel.activePaneID else { return }
        _ = tab.viewModel.workspace.resetPane(id.raw)
    }

    /// New Agent: a new pane seeded from the current one (same path + command).
    private func agentNewPane() {
        guard let tab = activeTab else { return }
        Task { await tab.viewModel.newFocusPane(.duplicateCurrent) }
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
    ///     state, not a server-side attach count (which would also count other
    ///     devices and lag behind the poll).
    ///   • color (filled only) — agent activity, highest priority first:
    ///     awaiting (amber) → done-unseen (green) → working (blue) → idle (gray).
    private enum SessionDot: String { case awaiting, doneUnseen, working, idle, dormant }

    private func sessionDot(for name: String) -> SessionDot {
        guard let tab = tabs.first(where: { $0.sessionKey == name }) else {
            return .dormant   // not open in Bento → hollow ring
        }
        let vm = tab.viewModel
        if vm.agentsWaiting > 0    { return .awaiting }
        if vm.agentsDoneUnseen > 0 { return .doneUnseen }
        if vm.agentsWorking > 0    { return .working }
        return .idle           // open, no agent activity → filled gray
    }

    /// Rendered dot images keyed by (dot, appearance). `rebuildTabBar` runs on
    /// every poll tick / VM publish — re-rasterizing identical NSImages each time
    /// is wasted work, and the stable instances also let `updateTabs` skip
    /// re-assigning unchanged segment images. Appearance is in the key because
    /// the neutral dots resolve semantic label colors at draw time.
    private var dotImageCache: [String: NSImage] = [:]

    /// Render a session-dot (memoized). Neutral grays use semantic label colors
    /// so they adapt to light/dark; the agent colors are fixed.
    private func dotImage(for dot: SessionDot) -> NSImage {
        let key = "\(dot.rawValue)-\(window.effectiveAppearance.name.rawValue)"
        if let cached = dotImageCache[key] { return cached }
        let img: NSImage
        switch dot {
        case .awaiting:   img = dotImage(PaneState.awaitingInput.nsColor, style: .filled)  // amber
        case .doneUnseen: img = dotImage(PaneTitleBar.doneColor, style: .filled)           // green
        case .working:    img = dotImage(PaneState.working.nsColor, style: .filled)                    // blue
        case .idle:       img = dotImage(.secondaryLabelColor, style: .filled)                         // attached, idle
        case .dormant:    img = dotImage(.tertiaryLabelColor, style: .ring)                            // not attached
        }
        dotImageCache[key] = img
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

    // MARK: Session history

    /// Session menu "History…" (and the folder-scoped pane variant): the
    /// shared history panel; picking an entry reopens the conversation and
    /// focuses wherever it landed.
    func presentHistoryPanel(initialDirectory: String? = nil) {
        SessionHistoryPanelController.shared.present(
            store: .shared, initialDirectory: initialDirectory
        ) { [weak self] entry in
            self?.openHistoryEntry(entry)
        }
    }

    private func openHistoryEntry(_ entry: CatalogEntry) {
        let preferred = activeTab?.viewModel.activeWorkspaceName
        guard let landed = AgentWorkspaceStore.shared.openHistorySession(
            entry, preferredSession: preferred) else { return }
        // The entry may have landed in another session (a live pane elsewhere,
        // or no attached session tab): bring that session forward.
        WorkspaceWindow.focusOrOpen(session: landed.session)
    }

    private func presentRenameSheet() {
        guard let tab = activeTab else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.viewModel.activeWorkspaceName ?? ""
        field.placeholderString = "workspace name"
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
        WorkspaceWindow.autoHideToolbarInFullscreen
            ? proposedOptions.union(.autoHideToolbar)
            : proposedOptions
    }

    // Fullscreen and end-of-drag are exactly the transitions that make a Focus
    // pane wide enough to want the dock (or narrow enough to give it back). Each
    // fires with the layout already settled, so `updateAutoDock` reads a real
    // width. (Live-resize frames are skipped on purpose — one decision at the
    // end, not one per frame.)
    func windowDidEnterFullScreen(_ notification: Notification) { updateAutoDock() }
    func windowDidExitFullScreen(_ notification: Notification) { updateAutoDock() }
    func windowDidEndLiveResize(_ notification: Notification) { updateAutoDock() }

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
