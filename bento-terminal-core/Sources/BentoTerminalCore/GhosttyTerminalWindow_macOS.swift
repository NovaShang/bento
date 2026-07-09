#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftTmux

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

    init(choice: TmuxStartChoice, title: String, key: String? = nil) {
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
            transport: LocalPtyTransport(command: nil),
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
            // Path preview: a plain tab is a local shell; cwd comes from the
            // shell's OSC 7 report (ghostty shell integration).
            surface.pathPreviewContext = PathPreviewContext(
                source: LocalFileSource(),
                cwd: { [weak surface] in surface?.reportedPwd },
                hostLabel: "This Mac",
                isLocal: true)
            vm.onRawDataReceived = { [weak surface] data in
                DispatchQueue.main.async { surface?.feed(data) }
            }
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
    /// Stable left-to-right order of the strip's segments. The poll's activity
    /// sort would reshuffle every refresh, so the strip keeps its own order and
    /// only appends/removes (see `reconcileSessionOrder`).
    private var sessionOrder: [String] = []
    /// The session currently shown (always loaded).
    private var activeKey: String?
    /// The sessions currently shown as segments (subset when overflowing).
    private var visibleSessions: [String] = []

    private let toolbar = TerminalToolbarController()
    private let container = NSView()
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
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.titleVisibility = .hidden

        container.autoresizesSubviews = true
        win.contentView = container

        // Toolbar: Sessions ⌄ | [session tabs] | New ⌄ | ⋯ — center hosts the
        // session tabs (every tmux session, loaded or not) as a Finder-style
        // segmented `NSToolbarItemGroup`.
        toolbar.onSelectSegment = { [weak self] idx in self?.segmentPicked(idx) }
        toolbar.onNewAgent = { BentoTerminalWindow.onNewAgentSession?() }
        toolbar.onNewTerminal = { BentoTerminalWindow.newSessionTab() }
        toolbar.onNewPlainShell = { BentoTerminalWindow.newWindowNoTmux() }
        toolbar.onOpenSettings = { BentoTerminalWindow.onOpenSettings?() }
        toolbar.onNewWindow = { [weak self] in self?.activeTab?.viewModel.newWindow() }
        toolbar.onSelectWindow = { [weak self] id in self?.activeTab?.viewModel.selectWindow(id) }
        toolbar.onCloseWindow = { [weak self] in self?.activeTab?.viewModel.closeWindow() }
        toolbar.onFitSession = { [weak self] in self?.activeTab?.paneHost?.refitSessionToWindow() }
        toolbar.onRenameWindow = { [weak self] in self?.presentWindowRenameSheet() }
        toolbar.onKillSession = { [weak self] in self?.killActiveSession() }
        toolbar.onDetach = { [weak self] in self?.detachActiveSession() }
        toolbar.onCloseTab = { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.removeTab(tab)   // plain tabs vanish; there's nothing to reconnect
        }
        toolbar.onRenameSession = { [weak self] in self?.presentRenameSheet() }
        win.toolbar = toolbar.makeToolbar()
        win.toolbarStyle = .unified
        win.center()
        self.window = win

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

    /// The full session list shown in the strip: every server session, plus any
    /// loaded session not yet reflected by the poll (just-created). Order is the
    /// STABLE `sessionOrder` (the poll sorts by activity, which would otherwise
    /// reshuffle the strip on every refresh).
    private func allSessions() -> [String] { sessionOrder }

    /// Reconcile `sessionOrder` against the live set: drop sessions that vanished,
    /// append newcomers (alphabetically for a deterministic first slot). Existing
    /// sessions never move — the strip behaves like browser tabs.
    private func reconcileSessionOrder() {
        var current = serverSessions
        for t in tabs where !current.contains(t.sessionKey) { current.append(t.sessionKey) }
        let set = Set(current)
        sessionOrder.removeAll { !set.contains($0) }
        let newcomers = current.filter { !sessionOrder.contains($0) }.sorted()
        sessionOrder.append(contentsOf: newcomers)
    }

    /// Pushed from the app's `tmux ls` poll — the machine's full session list.
    func updateServerSessions(_ names: [String]) {
        serverSessions = names
        if names.isEmpty && tabs.isEmpty { window.close(); return }
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

        if let active = activeTab {
            let name = active.viewModel.activeTmuxSessionName ?? active.windowTitle
            window.title = name
            toolbar.setSessionTitle(name)
            toolbar.activeTabIsPlain = active.isPlain
        }
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

    private func presentWindowRenameSheet() {
        guard let tab = activeTab else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Window"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = toolbar.activeWindowName
        field.placeholderString = "window name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            tab.viewModel.renameWindow(to: field.stringValue)
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
#endif
