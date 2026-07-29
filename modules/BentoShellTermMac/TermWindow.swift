#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoUI
import BentoWorkbench
import Combine
import SwiftUI

/// Product B's window layer. Its identity (docs/term-shell-port.md #1): **one
/// tmux session per NSWindow**, joined into a native macOS tab group by a
/// shared `tabbingIdentifier` — so ⌘⇧[/], drag-out, and Merge All Windows all
/// work. Ported from the frozen `BentoTerminalWindow` / `TerminalWindowManager`,
/// re-sourced off `TermWorkspaceModel` + the daemon structure mirror.
///
/// v1 boundary (flagged): the daemon is one-target-one-session, so v1 opens the
/// single `local` session; the native-tab machinery is ready for the multi-
/// target daemon extension that lights up more sessions.
@MainActor
public enum BentoTermWindow {
    private static var managers: [TermWindowManager] = []
    private static var nextEntryID = 1

    public static var isTerminating = false

    public nonisolated static let defaultSessionNameKey = "term_default_session_name"
    private nonisolated static let fallbackSessionName = "bento"
    public nonisolated static var defaultSessionName: String {
        let raw = UserDefaults.standard.string(forKey: defaultSessionNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? fallbackSessionName : raw
    }

    nonisolated static let lastSessionsKey = "term_last_sessions"
    static let frameName = "BentoTermWindow"
    private static var knownServerSessions: [String] = []

    /// App-provided hooks (live in the app target).
    public static var onNewAgentSession: (() -> Void)?
    public static var onOpenSettings: (() -> Void)?

    public static var hasOpenWindows: Bool { !managers.isEmpty }
    public static var openSessionKeys: Set<String> { Set(managers.map(\.sessionKey)) }

    static func manager(for key: String) -> TermWindowManager? {
        managers.first { $0.sessionKey == key }
    }
    private static func frontmostManager() -> TermWindowManager? {
        managers.first { $0.window.isKeyWindow } ?? managers.last
    }

    // MARK: Open

    public static func openMainWindow() {
        if let m = frontmostManager() { m.bringToFront(); return }
        var last = (UserDefaults.standard.stringArray(forKey: lastSessionsKey) ?? [])
            .filter { !$0.isEmpty }
        if !knownServerSessions.isEmpty {
            let live = Set(knownServerSessions)
            last = last.filter { live.contains($0) }
        }
        if last.isEmpty {
            newWindow(session: defaultSessionName)
        } else {
            for name in last { newWindow(session: name) }
        }
        (managers.first ?? frontmostManager())?.bringToFront()
    }

    public static func newWindow(session: String = defaultSessionName) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if let existing = manager(for: session) { existing.bringToFront(); return }
        addWindow(session: session).bringToFront()
        persistOpenSessions()
    }

    /// The native tab bar `+` and ⌘⇧T: a fresh uniquely-named session.
    public static func newSessionTab() {
        let open = openSessionKeys
        var n = max(open.count + 1, 2)
        var name = "session-\(n)"
        while open.contains(name) { n += 1; name = "session-\(n)" }
        newWindow(session: name)
    }

    /// Retired with the LocalPty stack — no plain (no-tmux) tabs in the trunk
    /// product (docs/term-shell-port.md #12). Kept as a no-op so the menu wiring
    /// still resolves; flagged for the daemon pty-kind follow-up.
    public static func newWindowNoTmux() {}

    @discardableResult
    private static func addWindow(session: String) -> TermWindowManager {
        let entryID = nextEntryID; nextEntryID += 1
        let m = TermWindowManager(sessionKey: session, entryID: entryID)
        m.onEmpty = { [weak m] in
            managers.removeAll { $0 === m }
            if !managers.isEmpty && !isTerminating { persistOpenSessions() }
            updateActivationPolicy()
        }
        if let host = frontmostManager()?.window {
            host.addTabbedWindow(m.window, ordered: .above)
        }
        managers.append(m)
        return m
    }

    // MARK: App-driven

    public static func setServerSessions(_ names: [String]) {
        knownServerSessions = names
        for m in managers { m.updateServerSessions(names) }
    }

    public static func closeMainWindow() { frontmostManager()?.requestClose() }
    public static func presentCommandPalette() { frontmostManager()?.presentSearch() }
    public static func trackActiveSessionSize() { frontmostManager()?.trackSize() }

    static func persistOpenSessions() {
        UserDefaults.standard.set(managers.map(\.sessionKey), forKey: lastSessionsKey)
    }

    static func updateActivationPolicy() {
        if managers.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    static func titleFor(_ session: String) -> String {
        session == defaultSessionName ? "Bento" : "Bento · \(session)"
    }
}

// MARK: - TermWindowManager (one NSWindow = one tmux session)

@MainActor
final class TermWindowManager: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow!
    private(set) var sessionKey: String
    let model: TermWorkspaceModel

    private let toolbar = TermToolbarController()
    private let paneHost: TermTiledPaneHost
    private let splitVC = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var sidebarHosting: NSHostingController<AnyView>!
    private let container = NSView()

    private var bag = Set<AnyCancellable>()
    private var serverSessions: [String] = []
    private var absentPolls = 0
    private static let absentPollsToClose = 4
    private static weak var frameOwner: NSWindow?

    var onEmpty: (() -> Void)?

    init(sessionKey: String, entryID: Int) {
        self.sessionKey = sessionKey
        self.model = TermWorkspaceModel(target: "local", sessionName: sessionKey, entryID: entryID)
        self.paneHost = TermTiledPaneHost(model: model, theme: ThemeStore.shared.makeCanvasTheme())
        super.init()

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.titleVisibility = .hidden
        win.tabbingIdentifier = "bento.terminal"
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titlebarSeparatorStyle = .none

        // System sidebar arrangement: a real sidebar split item (native
        // material, collapse, width autosave) + the tiled host as content.
        container.autoresizesSubviews = true
        sidebarHosting = NSHostingController(rootView: AnyView(EmptyView()))
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 340
        sidebar.allowsFullHeightLayout = true
        sidebar.isCollapsed = true
        sidebarItem = sidebar

        let contentVC = NSViewController()
        contentVC.view = container
        splitVC.addSplitViewItem(sidebar)
        splitVC.addSplitViewItem(NSSplitViewItem(viewController: contentVC))
        splitVC.splitView.autosaveName = "BentoTermSidebarSplit"
        win.contentViewController = splitVC
        win.setContentSize(NSSize(width: 980, height: 640))

        paneHost.frame = container.bounds
        paneHost.autoresizingMask = [.width, .height]
        container.addSubview(paneHost)

        applyWindowBackground(to: win)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: .terminalThemeChanged, object: nil)

        wireToolbar()
        win.toolbar = toolbar.makeToolbar()
        win.toolbarStyle = .unified

        // Frame owner: exactly one window owns the shared autosave name.
        if !BentoTermWindow.hasOpenWindows {
            Self.frameOwner = win
            win.setFrameAutosaveName(BentoTermWindow.frameName)
            if !win.setFrameUsingName(BentoTermWindow.frameName) { win.center() }
        } else {
            win.center()
        }
        window = win

        bindModel()
        model.start()
    }

    private func wireToolbar() {
        toolbar.sessionName = sessionKey
        toolbar.onSelectMode = { [weak self] mode in self?.model.setMode(mode) }
        toolbar.onSelectSegment = { [weak self] idx in self?.selectWindow(at: idx) }
        toolbar.onOpenSearch = { [weak self] in self?.presentSearch() }
        toolbar.onNewWindow = { [weak self] in self?.model.newWindow() }
        toolbar.onNewSession = { BentoTermWindow.newSessionTab() }
        toolbar.onOpenSettings = { BentoTermWindow.onOpenSettings?() }
        toolbar.onRenameSession = { [weak self] in self?.presentRenameSheet() }
        toolbar.onKillSession = { [weak self] in self?.killSession() }
        toolbar.onDetach = { [weak self] in self?.requestClose() }
        toolbar.onCloseWindow = { [weak self] in self?.requestClose() }
        toolbar.onTrackSize = { [weak self] in self?.trackSize() }
    }

    private func bindModel() {
        model.$mode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.toolbar.setMode(mode)
                self?.updateSidebar(mode: mode)
            }
            .store(in: &bag)
        model.$windows
            .receive(on: RunLoop.main)
            .sink { [weak self] windows in
                self?.toolbar.setWindows(windows.map(\.displayName),
                                         selected: windows.firstIndex(where: \.active) ?? 0)
            }
            .store(in: &bag)
        model.$sessionName
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] name in
                guard let self else { return }
                self.migrateSessionKey(to: name)
                self.window.title = name
                self.toolbar.sessionName = name
            }
            .store(in: &bag)
    }

    // MARK: Sidebar (Focus)

    private func updateSidebar(mode: WorkspaceViewMode) {
        let showing = mode == .list
        if showing {
            sidebarHosting.rootView = AnyView(TermWindowSidebar(model: model))
        } else {
            sidebarHosting.rootView = AnyView(EmptyView())
        }
        if sidebarItem.isCollapsed == showing {
            sidebarItem.animator().isCollapsed = !showing
        }
    }

    private func selectWindow(at index: Int) {
        guard model.windows.indices.contains(index) else { return }
        model.selectWindowIndex(model.windows[index].index)
    }

    // MARK: Chrome color

    private func applyWindowBackground(to win: NSWindow) {
        let bg = ThemeStore.shared.current.bg
        let color = NSColor(srgbRed: CGFloat((bg >> 16) & 0xff) / 255,
                            green: CGFloat((bg >> 8) & 0xff) / 255,
                            blue: CGFloat(bg & 0xff) / 255, alpha: 1)
        win.backgroundColor = color
    }

    @objc private func themeChanged() { applyWindowBackground(to: window) }

    // MARK: Actions

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
    func requestClose() { window.close() }
    func presentSearch() { BentoTermPaneAction.dispatch(BentoTermPaneAction.findInPane) }

    /// ⇧⌘R — re-assert this window's grid on the shared session. The sizing
    /// policy/owner state machine is an undesigned daemon seam
    /// (docs/term-shell-port.md #8); v1 ships `latest` (daemon default) and this
    /// re-fits by re-attaching the active pane's size. Flagged.
    func trackSize() {
        // No client-side sizing authority in v1: the daemon owns session size.
        // Left as an explicit user affordance that currently no-ops safely.
    }

    private func killSession() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Kill session “\(sessionKey)”?"
        alert.informativeText = "Every pane in this session is closed and its processes are terminated. This can’t be undone."
        alert.alertStyle = .warning
        let kill = alert.addButton(withTitle: "Kill Session")
        alert.addButton(withTitle: "Cancel")
        kill.keyEquivalent = ""
        if #available(macOS 11.0, *) { kill.hasDestructiveAction = true }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.model.killSession()
            self?.requestClose()
        }
    }

    private func presentRenameSheet() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = sessionKey
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.model.renameSession(to: field.stringValue)
        }
    }

    // MARK: Server poll → self-close / key migration

    func updateServerSessions(_ names: [String]) {
        serverSessions = names
        guard !names.isEmpty else { return }
        if !names.contains(sessionKey) {
            absentPolls += 1
            if absentPolls >= Self.absentPollsToClose { window.close() }
        } else {
            absentPolls = 0
        }
    }

    private func migrateSessionKey(to name: String) {
        guard !name.isEmpty, name != sessionKey else { return }
        if let other = BentoTermWindow.manager(for: name), other !== self {
            window.close()   // re-homed onto an existing session's window → close the dup
            return
        }
        sessionKey = name
        absentPolls = 0
        BentoTermWindow.persistOpenSessions()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Record the frame and hand the autosave name back (the eff25ec fix):
        // AppKit refuses a second window claiming a name still held.
        window.saveFrame(usingName: BentoTermWindow.frameName)
        if Self.frameOwner === window {
            window.setFrameAutosaveName("")
            Self.frameOwner = nil
        }
        bag.removeAll()
        sidebarHosting.rootView = AnyView(EmptyView())
        paneHost.teardown()
        model.teardown()
        NotificationCenter.default.removeObserver(self)
        window.toolbar = nil
        window.delegate = nil
        onEmpty?()
    }
}
#endif
