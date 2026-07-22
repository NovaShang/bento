#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

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
final class WorkspaceToolbar: NSObject, NSToolbarDelegate {
    var onNewAgent: (() -> Void)?
    var onNewTerminal: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onSelectPane: ((PaneID) -> Void)?
    var onRenameSession: (() -> Void)?
    var onDetach: (() -> Void)?
    var onKillSession: (() -> Void)?
    /// Open the session-history panel (past conversations, reopenable).
    var onShowHistory: (() -> Void)?
    /// The Tiled|List mode switch picked a mode (the manager runs `setMode`,
    /// warning first when a mixed external structure must be flattened).
    var onSelectMode: ((WorkspaceViewMode) -> Void)?
    var onMoveTabLeft: (() -> Void)?
    var onMoveTabRight: (() -> Void)?
    var onTogglePreview: (() -> Void)?

    // Agent-level actions — the Focus toolbar's New is scoped to the ACTIVE
    // agent. Wired by the window.
    /// Start a fresh conversation in the active pane (current one → history).
    var onNewChat: (() -> Void)?
    /// Spawn a new agent pane (duplicate the current one).
    var onNewAgentPane: (() -> Void)?
    /// Switch the window to another open/dormant workspace (from the workspace
    /// button's "Switch Workspace" menu — the low-frequency path in Focus).
    var onSelectWorkspace: ((String) -> Void)?
    /// All workspaces (name + whether it's the current one) for that menu.
    var workspaces: [(name: String, isCurrent: Bool)] = []
    /// The window's sidebar split view. Used to build the tracking separator that
    /// aligns the workspace button over the sidebar in Focus (à la Notes/Mail).
    weak var sidebarSplitView: NSSplitView?

    /// True while the active tab is in Focus (List) mode. The centered tabs give
    /// way to the agent name + state, and a tracking separator drops the
    /// workspace button over the sidebar.
    private var isFocusMode = false
    private var activeAgentName = "Agent"
    private var activeAgentStatus: PaneDisplayStatus = .idle
    /// The centered agent identity shown in Focus (name + state glyph), in place
    /// of the workspace tabs. A plain label — not interactive.
    private let agentTitleField = NSTextField(labelWithString: "")

    /// The session's panes (id + live display name) for the switch list in
    /// the session menu; ordinals match ⌘1-9. Windows are gone.
    var panes: [(id: PaneID, name: String)] = []
    var activePaneID: PaneID?
    /// Whether the active tab has a neighbor to swap with in each direction (drives
    /// the "Move Tab Left/Right" reorder items in the right-click menu).
    var canMoveTabLeft = false
    var canMoveTabRight = false

    private let sessionsButton = NSButton()
    /// Tiled|List — the session's structural mode, next to the session button.
    /// Reflects the active tab's `workspaceMode`; hidden for plain (raw-shell) tabs.
    private let modeSwitch = NSSegmentedControl()
    private let newButton = NSButton()
    private let moreButton = NSButton()
    /// Show/hide the preview dock (always present, like an inspector toggle).
    private let previewButton = NSButton()
    /// The sessions button's current label text — kept so its rasterized chevron
    /// can be rebuilt (with the same text) when the appearance changes.
    private var sessionsText = "Workspace"
    /// The session tabs, as a first-class segmented `NSToolbarItemGroup` (the way
    /// Finder builds its view-mode switcher) — NOT a control hosted in a view
    /// item, which macOS double-wraps in a group container. Rebuilt via the
    /// `titles:` convenience initializer (the same path Finder uses, which yields
    /// the real pill-selected segmented look) whenever the session set changes.
    private(set) var tabsGroup = NSToolbarItemGroup(itemIdentifier: WorkspaceToolbar.centerID)
    var onSelectSegment: ((Int) -> Void)?
    /// The toolbar that owns `tabsGroup` — so we can swap the group in place.
    private weak var toolbarRef: NSToolbar?
    /// Signature (title + dot) of the current segments. A group swap is needed
    /// whenever this changes — including a dot-only change, because mutating a
    /// live group's subitem images doesn't reliably re-render. Selection-only
    /// changes keep the same signature and just move `selectedIndex` in place.
    private var currentSig: [String] = []

    fileprivate static let sessionsID = NSToolbarItem.Identifier("bento.sessions")
    /// Separator that tracks the sidebar↔content divider (Focus only), so the
    /// workspace button before it aligns over the sidebar.
    fileprivate static let sidebarTrackingID = NSToolbarItem.Identifier("bento.sidebartracking")
    /// Centered agent identity, shown in Focus in place of the workspace tabs.
    fileprivate static let agentTitleID = NSToolbarItem.Identifier("bento.agenttitle")
    fileprivate static let modeID = NSToolbarItem.Identifier("bento.mode")
    fileprivate static let newID = NSToolbarItem.Identifier("bento.new")
    fileprivate static let moreID = NSToolbarItem.Identifier("bento.more")
    fileprivate static let centerID = NSToolbarItem.Identifier("bento.center")
    fileprivate static let previewID = NSToolbarItem.Identifier("bento.preview")

    override init() {
        super.init()
        // The left button is the CURRENT session's menu (named with the session,
        // like a document-title menu) — the discoverable home for per-session
        // actions. Its text is updated by the manager via `setSessionTitle`.
        configureMenu(sessionsButton, symbol: "macwindow", text: "Workspace",
                      action: #selector(sessionMenuTapped))
        // Tiled|List: the structure IS the mode, so this reads as a view switch
        // (lossless, instant) — the manager confirms only the mixed→List case.
        modeSwitch.segmentCount = 2
        modeSwitch.setLabel("Parallel", forSegment: 0)
        modeSwitch.setLabel("Focus", forSegment: 1)
        modeSwitch.trackingMode = .selectOne
        modeSwitch.controlSize = .large   // match the neighboring buttons
        modeSwitch.target = self
        modeSwitch.action = #selector(modeSwitched)
        modeSwitch.setToolTip("All panes tiled in one view", forSegment: 0)
        modeSwitch.setToolTip("One pane at a time, listed in the sidebar", forSegment: 1)
        modeSwitch.sizeToFit()
        configureMenu(newButton, symbol: "plus", text: "New", action: #selector(newTapped))
        // A plain gear that opens Settings directly (session actions moved to the
        // named session button on the left).
        configure(moreButton, symbol: "gearshape", title: "", action: #selector(settingsAction))
        moreButton.toolTip = "Settings"
        // Inspector-style toggle for the preview dock (file tree + previews).
        configure(previewButton, symbol: "sidebar.trailing", title: "",
                  action: #selector(previewTapped))
        previewButton.toolTip = "Show/hide the file panel (⌥⌘P)"
        configureGroup(tabsGroup)   // placeholder until the first updateTabs
        // Centered agent identity (Focus). A non-interactive label; its content
        // is rebuilt by `applyAgentTitle` as the active agent / its state change.
        agentTitleField.lineBreakMode = .byTruncatingTail
        agentTitleField.cell?.usesSingleLineMode = true
        agentTitleField.alignment = .center
        applyAgentTitle()
        // The menu chevrons are rasterized (non-template) images — unlike the
        // dynamic `.labelColor` text they sit beside, they can't re-resolve on
        // an appearance change and would keep their baked color (white from a
        // dark launch, wrong on a light title bar). Rebuild them when the theme
        // / system light-dark flips. Fires on appearanceMode change AND system flip.
        NotificationCenter.default.addObserver(
            self, selector: #selector(chromeAppearanceChanged),
            name: .terminalThemeChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func chromeAppearanceChanged() {
        // Defer one runloop tick so the buttons' effectiveAppearance has settled
        // (a system light/dark flip updates it just after the notification).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyWorkspaceButtonStyle(focus: self.isFocusMode)
            self.setMenuText(self.newButton, "New")
        }
    }

    /// Update the left button to name the active session (keeps its icon/chevron).
    /// In Focus the name lives in the tooltip instead (the button is icon-only).
    func setSessionTitle(_ name: String) {
        sessionsText = name.isEmpty ? "Workspace" : name
        if isFocusMode {
            sessionsButton.toolTip = sessionsText
        } else {
            setMenuText(sessionsButton, sessionsText)
        }
    }

    /// Reflect the active tab's mode on the Tiled|List switch AND swap the
    /// centered item: Parallel centers the workspace tabs; Focus centers the
    /// active agent's name + state (the left button stays the workspace menu,
    /// now sitting above the sidebar; workspace switching moves into its menu).
    func setSessionMode(_ mode: WorkspaceViewMode) {
        modeSwitch.selectedSegment = (mode == .tiled) ? 0 : 1
        setFocusChrome(mode == .list)
    }

    /// Feed the active agent's name + state (drives the centered Focus title).
    func setActiveAgent(name: String, status: PaneDisplayStatus) {
        activeAgentName = name.isEmpty ? "Agent" : name
        activeAgentStatus = status
        applyAgentTitle()   // only visible while the agent-title item is shown
    }

    /// Swap the toolbar between workspace-level (Parallel) and agent-level
    /// (Focus): a tracking separator drops the workspace button over the sidebar,
    /// and the centered tabs give way to the agent title. Idempotent.
    private func setFocusChrome(_ focus: Bool) {
        isFocusMode = focus
        applyWorkspaceButtonStyle(focus: focus)
        setTrackingSeparator(present: focus)
        if focus {
            setCenterItem(Self.centerID, present: false)
            setCenterItem(Self.agentTitleID, present: true)
        } else {
            setCenterItem(Self.agentTitleID, present: false)
            setCenterItem(Self.centerID, present: true)
        }
    }

    /// The workspace button lives above the sidebar in Focus, which can get
    /// narrow — and the name isn't important there. So Focus shows an icon-only
    /// button (name → tooltip + menu) that always fits; Parallel shows the name.
    private func applyWorkspaceButtonStyle(focus: Bool) {
        if focus {
            sessionsButton.image = NSImage(systemSymbolName: "macwindow",
                                           accessibilityDescription: sessionsText)
            sessionsButton.imagePosition = .imageOnly
            sessionsButton.attributedTitle = NSAttributedString(string: "")
            sessionsButton.title = ""
            sessionsButton.toolTip = sessionsText
            sessionsButton.sizeToFit()
        } else {
            sessionsButton.imagePosition = .imageLeading
            sessionsButton.toolTip = nil
            setMenuText(sessionsButton, sessionsText)
        }
    }

    /// Insert/remove the sidebar-tracking separator right after the workspace
    /// button. Present only in Focus (where the sidebar exists), so the button
    /// aligns over the sidebar column; removed in Parallel (no sidebar).
    private func setTrackingSeparator(present: Bool) {
        guard let tb = toolbarRef else { return }
        let idx = tb.items.firstIndex { $0.itemIdentifier == Self.sidebarTrackingID }
        if present, idx == nil,
           let s = tb.items.firstIndex(where: { $0.itemIdentifier == Self.sessionsID }) {
            tb.insertItem(withItemIdentifier: Self.sidebarTrackingID, at: s + 1)
        } else if !present, let i = idx {
            tb.removeItem(at: i)
        }
    }

    /// Insert/remove a centered toolbar item, placing it between the two flexible
    /// spaces (the centered home) when inserting.
    private func setCenterItem(_ id: NSToolbarItem.Identifier, present: Bool) {
        guard let tb = toolbarRef else { return }
        let idx = tb.items.firstIndex { $0.itemIdentifier == id }
        if present, idx == nil {
            if let f1 = tb.items.firstIndex(where: { $0.itemIdentifier == .flexibleSpace }) {
                tb.insertItem(withItemIdentifier: id, at: f1 + 1)
            }
        } else if !present, let i = idx {
            tb.removeItem(at: i)
        }
    }

    /// Paint the centered agent title: a colored state glyph + the agent's name.
    private func applyAgentTitle() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let s = NSMutableAttributedString()
        if let glyph = Self.agentGlyph(activeAgentStatus) {
            let att = NSTextAttachment()
            att.image = glyph
            att.bounds = CGRect(x: 0, y: (font.capHeight - glyph.size.height) / 2,
                                width: glyph.size.width, height: glyph.size.height)
            s.append(NSAttributedString(attachment: att))
            s.append(NSAttributedString(string: "  "))
        }
        s.append(NSAttributedString(string: activeAgentName,
                                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        agentTitleField.attributedStringValue = s
        agentTitleField.sizeToFit()
    }

    /// The state glyph for the agent title (same language as the pane chrome +
    /// sidebar): play / question / check / hollow ring, palette-colored.
    private static func agentGlyph(_ status: PaneDisplayStatus) -> NSImage? {
        let sym: String
        let hex: UInt32
        switch status {
        case .working:    sym = "play.circle.fill";         hex = PaneState.workingHex
        case .awaiting:   sym = "questionmark.circle.fill";  hex = PaneState.awaitingHex
        case .doneUnseen: sym = "checkmark.circle.fill";     hex = PaneState.doneUnseenHex
        case .idle:       sym = "circle";                    hex = PaneState.idleHex
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [PaneState.nsColor(hex: hex)]))
        let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = false
        return img
    }

    @objc private func modeSwitched() {
        onSelectMode?(modeSwitch.selectedSegment == 1 ? .list : .tiled)
    }

    private func configureGroup(_ g: NSToolbarItemGroup) {
        g.selectionMode = .selectOne
        g.controlRepresentation = .expanded
        g.target = self
        g.action = #selector(tabsGroupAction)
        g.label = "Workspaces"
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
            // Dot images are memoized upstream (same dot + appearance → same
            // instance), so an identity match means nothing to update — skip the
            // assignment rather than dirty the toolbar item every refresh. A
            // fresh group after swapGroup has nil images and always assigns.
            if sub.image !== items[i].image { sub.image = items[i].image }
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
        g.label = "Workspaces"
        tabsGroup = g
        guard let tb = toolbarRef,
              let idx = tb.items.firstIndex(where: { $0.itemIdentifier == Self.centerID })
        else { return }
        tb.removeItem(at: idx)
        tb.insertItem(withItemIdentifier: Self.centerID, at: idx)
    }

    @objc private func tabsGroupAction() { onSelectSegment?(tabsGroup.selectedIndex) }

    func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "BentoWorkspaceToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        // Pin the session strip to the WINDOW's center, independent of the side
        // items' widths — so the session-name button can size to its text without
        // ever nudging the tabs (the native alternative to hardcoding widths).
        // The agent title (Focus) is centered by its flexible spaces instead, so
        // it lands in the CONTENT region (right of the tracking separator), not
        // the whole window.
        tb.centeredItemIdentifiers = [Self.centerID]
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
        if let chevron = Self.chevronImage(pointSize: font.pointSize * 0.8,
                                           appearance: b.effectiveAppearance) {
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
    /// color inside an attributed title). Because it's baked, the dynamic
    /// `.labelColor` must be resolved to a CONCRETE color for the CURRENT
    /// appearance — otherwise it keeps whatever it resolved to at build time
    /// (e.g. dark-mode white) and looks wrong on a light title bar. The menu
    /// buttons rebuild it via `chromeAppearanceChanged` when the theme flips.
    private static func chevronImage(pointSize: CGFloat, appearance: NSAppearance) -> NSImage? {
        var label = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [label]))
        let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = false
        return img
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // ◧ | Sessions ⌄ | Tiled|List | ⸺flex⸺ | [session tabs] | ⸺flex⸺ | New ⌄ | ⋯ | ◨
        [Self.sessionsID, Self.modeID, .flexibleSpace, Self.centerID,
         .flexibleSpace, Self.newID, Self.moreID, Self.previewID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // agentTitleID + the tracking separator aren't in the default set
        // (Parallel launch), but must be allowed so the Focus swap can insert them.
        toolbarDefaultItemIdentifiers(toolbar) + [Self.agentTitleID, Self.sidebarTrackingID]
    }

    @objc private func previewTapped() { onTogglePreview?() }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // The session tabs ARE a group item (Finder-style) — return it directly,
        // not wrapped in a view item, so macOS doesn't double-nest a container.
        if id == Self.centerID { return tabsGroup }
        // The tracking separator needs the split view + the sidebar↔content
        // divider index (0). Aligns the items before it over the sidebar.
        if id == Self.sidebarTrackingID {
            guard let sv = sidebarSplitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: Self.sidebarTrackingID, splitView: sv, dividerIndex: 0)
        }
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.sessionsID:   item.view = sessionsButton;  item.label = "Workspace"
        case Self.agentTitleID: item.view = agentTitleField; item.label = "Agent"
        case Self.modeID:       item.view = modeSwitch;      item.label = "Layout"
        case Self.newID:      item.view = newButton;      item.label = "New"
        case Self.moreID:     item.view = moreButton;     item.label = "Settings"
        case Self.previewID:  item.view = previewButton;  item.label = "Preview"
        default: return nil
        }
        return item
    }

    // MARK: - Menus

    @objc private func sessionMenuTapped() {
        pop(sessionActionsMenu(), from: sessionsButton)
    }

    @objc private func newChatMenu() { onNewChat?() }
    @objc private func newAgentPaneMenu() { onNewAgentPane?() }
    @objc private func switchWorkspaceItem(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { onSelectWorkspace?(name) }
    }

    /// The current session's actions — the same menu the named left button and a
    /// right-click on the tab strip both present. Operates on the active session.
    /// Per the two-mode model, windows are de-emphasized here: only close and
    /// switch remain (compat) — creation lives in the List sidebar / pane split
    /// menus, and there is deliberately no rename (names derive live).
    func sessionActionsMenu() -> NSMenu {
        let menu = NSMenu()
        // Switch to another workspace — the workspace button carries this in
        // Focus (the centered tabs give way to the agent title there). A submenu
        // keeps the menu compact; only shown when there's somewhere to go.
        let others = workspaces.filter { !$0.isCurrent }
        if !others.isEmpty {
            let sub = NSMenu()
            for ws in others {
                let it = NSMenuItem(title: ws.name, action: #selector(switchWorkspaceItem(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = ws.name
                sub.addItem(it)
            }
            let root = NSMenuItem(title: "Switch Workspace", action: nil, keyEquivalent: "")
            root.submenu = sub
            menu.addItem(root)
            menu.addItem(.separator())
        }
        // Reorder the active tab in the strip. Only the available direction(s) are
        // shown (native segmented controls can't be dragged, so this is the reorder
        // affordance). Applies to plain tabs too — they're in the strip as well.
        addMoveItems(to: menu)
        add(menu, "Rename Workspace…", #selector(renameAction))
        add(menu, "Detach (keep running)", #selector(detachAction))  // unload; session survives
        add(menu, "Kill Workspace", #selector(killAction))             // destroy the workspace session
        menu.addItem(.separator())
        add(menu, "History…", #selector(historyAction))              // past conversations, reopenable
        // Switch list — every pane in this session, the current one
        // checkmarked (ordinals match ⌘1-9).
        if panes.count > 1 {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Panes", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (idx, p) in panes.enumerated() {
                let name = p.name.trimmingCharacters(in: .whitespaces)
                let title = name.isEmpty ? "\(idx + 1)" : "\(idx + 1): \(name)"
                let it = NSMenuItem(title: title, action: #selector(selectPaneAction(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = p.id
                it.state = (p.id == activePaneID) ? .on : .off
                menu.addItem(it)
            }
        }
        return menu
    }

    /// The ways to create something, each a plain title + a one-line explanation.
    /// (Per-session "New Pane" lives in the session menu, not here.)
    @objc private func newTapped() {
        // Focus: New is agent-level — a fresh chat in this pane, or a new agent.
        if isFocusMode {
            let menu = NSMenu()
            add(menu, "New Chat", #selector(newChatMenu))
            add(menu, "New Agent", #selector(newAgentPaneMenu))
            pop(menu, from: newButton)
            return
        }
        let menu = NSMenu()
        menu.addItem(richItem(
            symbol: "square.grid.2x2", title: "New Multi Pane Workspace",
            note: "Set up an AI agent (Claude, Codex…) in a fresh workspace laid out in panes.",
            action: #selector(newAgentAction)))
        menu.addItem(richItem(
            symbol: "clock.arrow.circlepath", title: "New Persistent Workspace",
            note: "A blank workspace that keeps running in the background — reconnect anytime.",
            action: #selector(newTerminalAction)))
        pop(menu, from: newButton)
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

    /// Prepend the reorder items for the available direction(s), then a separator.
    /// Unavailable directions are omitted (rather than disabled) so the menu stays
    /// clean at the ends of the strip.
    private func addMoveItems(to menu: NSMenu) {
        var added = false
        if canMoveTabLeft { add(menu, "Move Tab Left", #selector(moveTabLeftAction)); added = true }
        if canMoveTabRight { add(menu, "Move Tab Right", #selector(moveTabRightAction)); added = true }
        if added { menu.addItem(.separator()) }
    }

    private func pop(_ menu: NSMenu, from button: NSView) {
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
    }

    // MARK: - Actions

    @objc private func newAgentAction() { onNewAgent?() }
    @objc private func newTerminalAction() { onNewTerminal?() }
    @objc private func moveTabLeftAction() { onMoveTabLeft?() }
    @objc private func moveTabRightAction() { onMoveTabRight?() }
    @objc private func settingsAction() { onOpenSettings?() }
    @objc private func renameAction() { onRenameSession?() }
    @objc private func detachAction() { onDetach?() }
    @objc private func killAction() { onKillSession?() }
    @objc private func historyAction() { onShowHistory?() }
    @objc private func selectPaneAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? PaneID { onSelectPane?(id) }
    }
}

#endif
