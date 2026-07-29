#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoWorkbench

/// The product-B toolbar: `[▢ session ⌄][Parallel│Focus] — [window strip] —
/// [🔍][＋New][⚙]`. Ported from the frozen `TerminalToolbarController`
/// (GhosttyTerminalTabBar), re-sourced off `TermWorkspaceModel`: the center
/// strip lists tmux WINDOWS (`index:name`), the left button pops session
/// actions, the segmented control toggles Parallel/Focus. The palette anchor
/// is exposed so the window can drop a search panel over the field.
///
/// Simplifications vs frozen (flagged): the SSH/plain-shell New items are gone
/// with the SSH/LocalPty retirement; the sizing-owner submenu is a single
/// "Track Session Size" item (the owner state machine is an undesigned daemon
/// seam — docs/term-shell-port.md #8).
@MainActor
public final class TermToolbarController: NSObject, NSToolbarDelegate {
    // Callbacks the window wires.
    public var onSelectMode: ((WorkspaceViewMode) -> Void)?
    public var onSelectSegment: ((Int) -> Void)?
    public var onOpenSearch: (() -> Void)?
    public var onNewWindow: (() -> Void)?
    public var onNewSession: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onRenameSession: (() -> Void)?
    public var onKillSession: (() -> Void)?
    public var onDetach: (() -> Void)?
    public var onCloseWindow: (() -> Void)?
    public var onTrackSize: (() -> Void)?

    // State the window pushes.
    public var sessionName = "" { didSet { setMenuText(sessionsButton, sessionName.isEmpty ? "Session" : sessionName) } }

    private static let sessionsID = NSToolbarItem.Identifier("bento.term.sessions")
    private static let modeID = NSToolbarItem.Identifier("bento.term.mode")
    private static let centerID = NSToolbarItem.Identifier("bento.term.center")
    private static let searchID = NSToolbarItem.Identifier("bento.term.search")
    private static let newID = NSToolbarItem.Identifier("bento.term.new")
    private static let settingsID = NSToolbarItem.Identifier("bento.term.settings")

    private let sessionsButton = NSButton()
    private let modeSwitch = NSSegmentedControl()
    private let searchButton = NSButton()
    private let newButton = NSButton()
    private let settingsButton = NSButton()
    private var tabsGroup = NSToolbarItemGroup(itemIdentifier: TermToolbarController.centerID)
    private weak var toolbarRef: NSToolbar?
    private var windowTitles: [String] = []

    /// Whatever search control is on screen — the palette anchors here.
    public var searchAnchor: NSView { searchButton }

    public override init() {
        super.init()
        configure(sessionsButton, symbol: "square.grid.2x2", action: #selector(sessionTapped))
        setMenuText(sessionsButton, "Session")

        modeSwitch.segmentCount = 2
        modeSwitch.setLabel("Parallel", forSegment: 0)
        modeSwitch.setLabel("Focus", forSegment: 1)
        modeSwitch.trackingMode = .selectOne
        modeSwitch.selectedSegment = 0
        modeSwitch.controlSize = .large
        modeSwitch.target = self
        modeSwitch.action = #selector(modeSwitched)

        configure(searchButton, symbol: "magnifyingglass", action: #selector(searchTapped))
        searchButton.toolTip = "Search commands, windows, panes (⌘P)"
        configure(newButton, symbol: "plus", action: #selector(newTapped))
        newButton.toolTip = "New"
        configure(settingsButton, symbol: "gearshape", action: #selector(settingsTapped))
        settingsButton.toolTip = "Settings"
    }

    private func configure(_ b: NSButton, symbol: String, action: Selector) {
        b.bezelStyle = .texturedRounded
        b.controlSize = .large
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageOnly
        b.target = self
        b.action = action
        b.sizeToFit()
    }

    private func setMenuText(_ b: NSButton, _ text: String) {
        b.imagePosition = .imageLeading
        b.title = text + "  ⌄"
        b.sizeToFit()
    }

    public func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "BentoTermToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        tb.centeredItemIdentifiers = [Self.centerID]
        toolbarRef = tb
        return tb
    }

    public func setMode(_ mode: WorkspaceViewMode) {
        modeSwitch.selectedSegment = mode == .list ? 1 : 0
    }

    /// Rebuild the center strip from the session's tmux windows. Uses the
    /// `titles:` group init (the only path that renders Finder's pill-selected
    /// look), and only when the titles actually changed.
    public func setWindows(_ titles: [String], selected: Int) {
        guard titles != windowTitles else {
            if tabsGroup.subitems.indices.contains(selected) { tabsGroup.selectedIndex = selected }
            return
        }
        windowTitles = titles
        swapGroup(titles: titles, selected: selected)
    }

    private func swapGroup(titles: [String], selected: Int) {
        let g = NSToolbarItemGroup(
            itemIdentifier: Self.centerID,
            titles: titles.isEmpty ? [""] : titles,
            selectionMode: .selectOne, labels: nil,
            target: self, action: #selector(tabsGroupAction))
        g.controlRepresentation = .expanded
        g.label = "Windows"
        if titles.indices.contains(selected) { g.selectedIndex = selected }
        tabsGroup = g
        guard let tb = toolbarRef, let idx = tb.items.firstIndex(where: { $0.itemIdentifier == Self.centerID }) else { return }
        tb.removeItem(at: idx)
        tb.insertItem(withItemIdentifier: Self.centerID, at: idx)
    }

    // MARK: NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sessionsID, Self.modeID, .flexibleSpace, Self.centerID, .flexibleSpace,
         Self.searchID, Self.newID, Self.settingsID]
    }
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.centerID { return tabsGroup }
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.sessionsID: item.view = sessionsButton
        case Self.modeID: item.view = modeSwitch
        case Self.searchID: item.view = searchButton
        case Self.newID: item.view = newButton
        case Self.settingsID: item.view = settingsButton
        default: return nil
        }
        return item
    }

    // MARK: Actions

    @objc private func modeSwitched() {
        onSelectMode?(modeSwitch.selectedSegment == 1 ? .list : .tiled)
    }
    @objc private func tabsGroupAction() { onSelectSegment?(tabsGroup.selectedIndex) }
    @objc private func searchTapped() { onOpenSearch?() }
    @objc private func settingsTapped() { onOpenSettings?() }
    @objc private func newTapped() {
        let menu = NSMenu()
        add(menu, "New tmux Window", #selector(newWindowAction), symbol: "macwindow")
        add(menu, "New Session", #selector(newSessionAction), symbol: "rectangle.stack")
        pop(menu, from: newButton)
    }
    @objc private func newWindowAction() { onNewWindow?() }
    @objc private func newSessionAction() { onNewSession?() }

    @objc private func sessionTapped() { sessionActionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sessionsButton.bounds.height), in: sessionsButton) }

    /// The left session button's actions (rename / sizing / detach / kill /
    /// close). Public so a window right-click can pop it too.
    public func sessionActionsMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, "Rename Session…", #selector(renameAction))
        add(menu, "Track Session Size to This Window", #selector(trackSizeAction), symbol: "arrow.up.left.and.arrow.down.right")
        menu.addItem(.separator())
        add(menu, "Detach (keep running)", #selector(detachAction))
        menu.addItem(.separator())
        add(menu, "Kill Session", #selector(killAction))
        add(menu, "Close Window", #selector(closeWindowAction))
        return menu
    }

    @objc private func renameAction() { onRenameSession?() }
    @objc private func trackSizeAction() { onTrackSize?() }
    @objc private func detachAction() { onDetach?() }
    @objc private func killAction() { onKillSession?() }
    @objc private func closeWindowAction() { onCloseWindow?() }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, symbol: String? = nil) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        if let symbol { it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(it)
    }

    private func pop(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }
}
#endif
