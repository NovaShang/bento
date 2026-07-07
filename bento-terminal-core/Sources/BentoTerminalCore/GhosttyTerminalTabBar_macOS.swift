#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftTmux

/// The unified title-bar toolbar for a session window.
///
/// Each item is a stock bordered `NSButton` hosted in an `NSToolbarItem.view`,
/// so the icon and text sit side by side (a view-less item can only stack the
/// label below the icon) while macOS still styles the button per OS version
/// (borderless ≤14, bordered "glass" on 26+).
///
/// Layout (left → right):
///   [▢ <session> ⌄]   ⸺flex⸺   [＋ New ⌄]   [⋯]
/// The Sessions button pops the menubar's two-level session list; New pops the
/// four creation methods (each with a plain title + one-line description); ⋯
/// holds this-session actions plus Settings.
@MainActor
final class TerminalToolbarController: NSObject, NSToolbarDelegate {
    var onToggleSidebar: (() -> Void)?
    var onNewAgent: (() -> Void)?
    var onNewTerminal: (() -> Void)?
    var onNewWindow: (() -> Void)?
    var onNewPlainShell: (() -> Void)?
    var onNewSSHHost: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onSelectWindow: ((TmuxWindowID) -> Void)?
    var onRenameWindow: (() -> Void)?
    var onCloseWindow: (() -> Void)?
    var onRenameSession: (() -> Void)?
    var onDetach: (() -> Void)?
    var onKillSession: (() -> Void)?
    var onFitSession: (() -> Void)?
    var onCloseTab: (() -> Void)?

    var windows: [SwiftTmux.TmuxWindow] = []
    var activeWindowID: TmuxWindowID?
    /// The active tab is a plain (no-tmux) terminal — its menu is just "Close".
    var activeTabIsPlain = false

    private let sidebarButton = NSButton()
    private let sessionsButton = NSButton()
    private let newButton = NSButton()
    private let moreButton = NSButton()
    /// The session tabs, as a first-class segmented `NSToolbarItemGroup` (the way
    /// Finder builds its view-mode switcher) — NOT a control hosted in a view
    /// item, which macOS double-wraps in a group container. Rebuilt via the
    /// `titles:` convenience initializer (the same path Finder uses, which yields
    /// the real pill-selected segmented look) whenever the session set changes.
    private(set) var tabsGroup = NSToolbarItemGroup(itemIdentifier: TerminalToolbarController.centerID)
    var onSelectSegment: ((Int) -> Void)?
    /// The toolbar that owns `tabsGroup` — so we can swap the group in place.
    private weak var toolbarRef: NSToolbar?
    /// Signature (title + dot) of the current segments. A group swap is needed
    /// whenever this changes — including a dot-only change, because mutating a
    /// live group's subitem images doesn't reliably re-render. Selection-only
    /// changes keep the same signature and just move `selectedIndex` in place.
    private var currentSig: [String] = []

    fileprivate static let sidebarID = NSToolbarItem.Identifier("bento.sidebar")
    fileprivate static let sessionsID = NSToolbarItem.Identifier("bento.sessions")
    fileprivate static let newID = NSToolbarItem.Identifier("bento.new")
    fileprivate static let moreID = NSToolbarItem.Identifier("bento.more")
    fileprivate static let centerID = NSToolbarItem.Identifier("bento.center")

    override init() {
        super.init()
        // Leading edge: collapse/expand the session-tree sidebar (the standard
        // macOS placement — Finder, Mail, Notes all lead with this toggle).
        configure(sidebarButton, symbol: "sidebar.left", title: "", action: #selector(toggleSidebarAction))
        sidebarButton.toolTip = "Show or Hide Sidebar"
        // The left button is the CURRENT session's menu (named with the session,
        // like a document-title menu) — the discoverable home for per-session
        // actions. Its text is updated by the manager via `setSessionTitle`.
        configureMenu(sessionsButton, symbol: "macwindow", text: "Session",
                      action: #selector(sessionMenuTapped))
        configureMenu(newButton, symbol: "plus", text: "New", action: #selector(newTapped))
        // A plain gear that opens Settings directly (session actions moved to the
        // named session button on the left).
        configure(moreButton, symbol: "gearshape", title: "", action: #selector(settingsAction))
        moreButton.toolTip = "Settings"
        configureGroup(tabsGroup)   // placeholder until the first updateTabs
    }

    /// Update the left button to name the active session (keeps its icon/chevron).
    func setSessionTitle(_ name: String) {
        setMenuText(sessionsButton, name.isEmpty ? "Session" : name)
    }

    private func configureGroup(_ g: NSToolbarItemGroup) {
        g.selectionMode = .selectOne
        g.controlRepresentation = .expanded
        g.target = self
        g.action = #selector(tabsGroupAction)
        g.label = "Sessions"
    }

    /// Refresh the session segments (titles + agent dots) and the selection. The
    /// segmented control is rebuilt (via the `titles:` convenience initializer —
    /// the same path Finder uses, which renders the proper pill-selected segments)
    /// whenever a title OR a dot changes; a selection-only change just moves the
    /// `selectedIndex` in place.
    func updateTabs(_ items: [(title: String, key: String, image: NSImage?)], selected: Int) {
        let sig = items.map { "\($0.title)\u{1}\($0.key)" }
        if sig != currentSig {
            currentSig = sig
            swapGroup(titles: items.map(\.title))
        }
        for (i, sub) in tabsGroup.subitems.enumerated() where i < items.count {
            sub.image = items[i].image
        }
        if tabsGroup.subitems.indices.contains(selected) { tabsGroup.selectedIndex = selected }
    }

    /// Rebuild the group with the convenience initializer and re-insert it into
    /// the toolbar (the only way to get Finder's exact segmented appearance — a
    /// hand-built `subitems` array renders as faint plain text instead).
    private func swapGroup(titles: [String]) {
        let g = NSToolbarItemGroup(
            itemIdentifier: Self.centerID,
            titles: titles.isEmpty ? [""] : titles,
            selectionMode: .selectOne,
            labels: nil,
            target: self,
            action: #selector(tabsGroupAction))
        g.controlRepresentation = .expanded
        g.label = "Sessions"
        tabsGroup = g
        guard let tb = toolbarRef,
              let idx = tb.items.firstIndex(where: { $0.itemIdentifier == Self.centerID })
        else { return }
        tb.removeItem(at: idx)
        tb.insertItem(withItemIdentifier: Self.centerID, at: idx)
    }

    @objc private func tabsGroupAction() { onSelectSegment?(tabsGroup.selectedIndex) }

    func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "BentoTerminalToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        toolbarRef = tb
        return tb
    }

    /// A plain action/icon button (no dropdown chevron).
    private func configure(_ b: NSButton, symbol: String, title: String, action: Selector) {
        b.bezelStyle = .texturedRounded
        b.controlSize = .large   // match the .large segmented tab strip's height
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? "More" : title)
        b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        b.title = title
        b.target = self
        b.action = action
        b.sizeToFit()
    }

    /// A menu button: leading icon (native image slot) + text + a vertically
    /// centered trailing `chevron.down` (a sized SF Symbol image embedded in the
    /// title, so it sits at the trailing edge instead of a misplaced "⌄" glyph).
    private func configureMenu(_ b: NSButton, symbol: String, text: String, action: Selector) {
        b.bezelStyle = .texturedRounded
        b.controlSize = .large   // match the .large segmented tab strip's height
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        b.imagePosition = .imageLeading
        b.target = self
        b.action = action
        setMenuText(b, text)
    }

    private func setMenuText(_ b: NSButton, _ text: String) {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let title = NSMutableAttributedString(
            string: text + "  ",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let chevron = Self.chevronImage(pointSize: font.pointSize * 0.8) {
            let att = NSTextAttachment()
            att.image = chevron
            att.bounds = CGRect(x: 0, y: (font.capHeight - chevron.size.height) / 2,
                                width: chevron.size.width, height: chevron.size.height)
            title.append(NSAttributedString(attachment: att))
        }
        b.attributedTitle = title
        b.sizeToFit()
    }

    /// `chevron.down` rendered in the label color (non-template so it keeps that
    /// color inside an attributed title).
    private static func chevronImage(pointSize: CGFloat) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = false
        return img
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // ◧ | Sessions ⌄ | ⸺flex⸺ | [session tabs] | ⸺flex⸺ | New ⌄ | ⋯
        [Self.sidebarID, Self.sessionsID, .flexibleSpace, Self.centerID,
         .flexibleSpace, Self.newID, Self.moreID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // The session tabs ARE a group item (Finder-style) — return it directly,
        // not wrapped in a view item, so macOS doesn't double-nest a container.
        if id == Self.centerID { return tabsGroup }
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.sidebarID:  item.view = sidebarButton;  item.label = "Sidebar"
        case Self.sessionsID: item.view = sessionsButton; item.label = "Session"
        case Self.newID:      item.view = newButton;      item.label = "New"
        case Self.moreID:     item.view = moreButton;     item.label = "Settings"
        default: return nil
        }
        return item
    }

    // MARK: - Menus

    @objc private func sessionMenuTapped() {
        pop(sessionActionsMenu(), from: sessionsButton)
    }

    /// The current session's actions — the same menu the named left button and a
    /// right-click on the tab strip both present. Operates on the active session.
    /// Holds full window management (new / rename / close / switch), tucked under a
    /// "Windows" subsection so the (de-emphasized) window concept stays out of the
    /// way while remaining complete.
    func sessionActionsMenu() -> NSMenu {
        let menu = NSMenu()
        // A plain (no-tmux) terminal has no session/windows — just close it.
        if activeTabIsPlain {
            add(menu, "Close Terminal", #selector(closeTabAction))
            return menu
        }
        add(menu, "Rename Session…", #selector(renameAction))
        // Re-assert THIS window's size on the session — for when another
        // attached client (an iPad) shrank the shared canvas.
        add(menu, "Fit Session to This Window", #selector(fitSessionAction))
        add(menu, "Detach (keep running)", #selector(detachAction))  // unload; session survives
        add(menu, "Kill Session", #selector(killAction))             // destroy the tmux session
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Windows", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        add(menu, "New Window", #selector(newWindowAction))
        add(menu, "Rename Window…", #selector(renameWindowAction))
        add(menu, "Close Window", #selector(closeWindowAction))
        // Switch list — every window in this session, the current one checkmarked.
        if windows.count > 1 {
            menu.addItem(.separator())
            for (idx, w) in windows.enumerated() {
                let name = w.name.trimmingCharacters(in: .whitespaces)
                let title = name.isEmpty ? "\(idx + 1)" : "\(idx + 1): \(name)"
                let it = NSMenuItem(title: title, action: #selector(selectWindowAction(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = w.id
                it.state = (w.id == activeWindowID) ? .on : .off
                menu.addItem(it)
            }
        }
        return menu
    }

    /// Name of the active tmux window (for prefilling the rename sheet).
    var activeWindowName: String {
        windows.first { $0.id == activeWindowID }?.name.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The ways to create something, each a plain title + a one-line explanation.
    /// (Per-session "New Window" lives in the session menu, not here.)
    @objc private func newTapped() {
        let menu = NSMenu()
        menu.addItem(richItem(
            symbol: "square.grid.2x2", title: "New Multi Pane Session",
            note: "Set up an AI agent (Claude, Codex…) in a fresh tmux session laid out in panes.",
            action: #selector(newAgentAction)))
        menu.addItem(richItem(
            symbol: "clock.arrow.circlepath", title: "New Persistent Session",
            note: "A blank tmux session that keeps running on the server — reconnect anytime.",
            action: #selector(newTerminalAction)))
        menu.addItem(.separator())
        menu.addItem(richItem(
            symbol: "terminal", title: "New Plain Terminal",
            note: "A quick shell with no tmux. Opens as a tab; closing it discards it for good.",
            action: #selector(newPlainShellAction)))
        let ssh = richItem(
            symbol: "network", title: "New SSH Connection",
            note: "Open a terminal connected to a host from your ~/.ssh/config.",
            action: nil)
        ssh.submenu = sshHostsSubmenu()
        menu.addItem(ssh)
        pop(menu, from: newButton)
    }

    /// One item per concrete host in ~/.ssh/config (re-read on every open, so
    /// config edits show up immediately); a disabled hint when there are none —
    /// including a missing or unreadable config.
    private func sshHostsSubmenu() -> NSMenu {
        let menu = NSMenu()
        let hosts = SSHConfigHosts.hosts()
        if hosts.isEmpty {
            menu.addItem(NSMenuItem(title: "No hosts in ~/.ssh/config", action: nil, keyEquivalent: ""))
            return menu
        }
        for host in hosts {
            let item = NSMenuItem(title: host, action: #selector(newSSHHostAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = host
            menu.addItem(item)
        }
        return menu
    }

    /// A menu item with a larger SF Symbol, a bold title, and a smaller grey note
    /// balanced onto two lines (an NSMenu sizes to the widest line, so the note is
    /// split in half rather than left as one long line that blows the menu out).
    private func richItem(symbol: String, title: String, note: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(cfg)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ])
        text.append(NSAttributedString(string: "\n" + balancedTwoLines(note), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]))
        item.attributedTitle = text
        return item
    }

    /// Split `text` into exactly two lines at the word boundary that makes the two
    /// lines the most even — keeps every note to two lines and the menu narrow.
    private func balancedTwoLines(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return text }
        let total = words.reduce(0) { $0 + $1.count } + (words.count - 1)
        var bestSplit = 1, bestDiff = Int.max
        for split in 1..<words.count {
            let line1 = words[0..<split].joined(separator: " ").count
            let diff = abs(line1 - (total - line1 - 1))
            if diff < bestDiff { bestDiff = diff; bestSplit = split }
        }
        return words[0..<bestSplit].joined(separator: " ") + "\n"
             + words[bestSplit...].joined(separator: " ")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func pop(_ menu: NSMenu, from button: NSView) {
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
    }

    // MARK: - Actions

    @objc private func toggleSidebarAction() { onToggleSidebar?() }
    @objc private func newAgentAction() { onNewAgent?() }
    @objc private func newTerminalAction() { onNewTerminal?() }
    @objc private func newWindowAction() { onNewWindow?() }
    @objc private func renameWindowAction() { onRenameWindow?() }
    @objc private func closeWindowAction() { onCloseWindow?() }
    @objc private func closeTabAction() { onCloseTab?() }
    @objc private func newPlainShellAction() { onNewPlainShell?() }
    @objc private func newSSHHostAction(_ sender: NSMenuItem) {
        if let host = sender.representedObject as? String { onNewSSHHost?(host) }
    }
    @objc private func settingsAction() { onOpenSettings?() }
    @objc private func renameAction() { onRenameSession?() }
    @objc private func detachAction() { onDetach?() }
    @objc private func killAction() { onKillSession?() }
    @objc private func fitSessionAction() { onFitSession?() }
    @objc private func selectWindowAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? TmuxWindowID { onSelectWindow?(id) }
    }
}

#endif
