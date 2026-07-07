#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftTmux

/// LEFT sidebar tree for the terminal window: every session on the machine as a
/// top-level row and — for sessions loaded as tabs — that session's tmux windows
/// as children. This is the window-per-agent navigation surface: tmux windows
/// are promoted to first-class (one agent per window), so the tree reads
/// "sessions of agents" at a glance, each window row carrying the aggregate
/// state dot of its panes.
///
/// Hand-rolled rows (matching the pane host / tab strip style) instead of an
/// NSOutlineView: the tree is tiny (sessions × windows), always fully expanded,
/// and full control over dots / badges / context menus costs less than fighting
/// outline-view cell reuse for a handful of rows.
@MainActor
final class SessionSidebarView: NSVisualEffectView {
    /// Fixed sidebar width — a source list, not a resizable split.
    static let preferredWidth: CGFloat = 220

    // MARK: - Model

    /// What the sidebar knows about one session, mirroring the tab strip's three
    /// segment flavors (dormant ring / plain terminal glyph / live tmux).
    enum SessionKind {
        /// Exists on the server but isn't loaded here — session row only.
        case dormant
        /// Loaded, but plain (no tmux) — no windows to list.
        case plain
        /// Loaded tmux session — its windows become child rows.
        case tmux(TerminalViewModel)
    }

    struct Entry {
        let name: String
        let kind: SessionKind
    }

    /// Click a session row → the manager loads/selects that session.
    var onSelectSession: ((String) -> Void)?
    /// Click a window row → select the session, then that tmux window.
    var onSelectWindow: ((String, TmuxWindowID) -> Void)?

    private var entries: [Entry] = []
    private var activeSession: String?

    private let scrollView = NSScrollView()
    private let listView = FlippedListView()
    /// Per-session Combine bags: each loaded VM's structure + agent activity
    /// drives a row reload, so dots/badges stay live while the session is in
    /// the background (control mode keeps streaming every window's output).
    private var cancellables: [String: Set<AnyCancellable>] = [:]

    // MARK: - Setup

    init() {
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        listView.autoresizingMask = [.width]
        scrollView.documentView = listView
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    // MARK: - Data in (pushed by TerminalWindowManager)

    /// Replace the tree's model. Called whenever the manager's session set or
    /// selection changes; the sidebar then keeps ITSELF current between pushes
    /// via the per-VM subscriptions below.
    func update(entries: [Entry], activeSession: String?) {
        self.entries = entries
        self.activeSession = activeSession
        resubscribe()
        reloadRows()
    }

    /// Re-key the Combine bags to the current entry set. Rebuilt wholesale on
    /// every push — update() isn't hot, and it keeps the bags from outliving a
    /// detached/killed session's VM.
    private func resubscribe() {
        cancellables.removeAll()
        for entry in entries {
            guard case .tmux(let vm) = entry.kind else { continue }
            var bag = Set<AnyCancellable>()
            // Structure: window list, pane→window mapping, active window.
            vm.$windows
                .combineLatest(vm.$sessionPanes, vm.$activeWindowID)
                .receive(on: RunLoop.main)
                .sink { [weak self] _, _, _ in self?.reloadRows() }
                .store(in: &bag)
            // Agent activity: windowState() reads the detector directly, so use
            // the aggregate counters as the "something changed" tick (same
            // signal the tab strip's dots use).
            vm.$agentsWorking
                .combineLatest(vm.$agentsWaiting, vm.$agentsDoneUnseen)
                .receive(on: RunLoop.main)
                .sink { [weak self] _, _, _ in self?.reloadRows() }
                .store(in: &bag)
            cancellables[entry.name] = bag
        }
    }

    // MARK: - Row building

    private func reloadRows() {
        listView.subviews.forEach { $0.removeFromSuperview() }
        let width = max(bounds.width, Self.preferredWidth)
        var y: CGFloat = 10

        let header = NSTextField(labelWithString: "Sessions")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 16, y: y, width: width - 32, height: 14)
        header.autoresizingMask = [.width]
        listView.addSubview(header)
        y += 20

        for entry in entries {
            addRow(sessionRow(for: entry), at: &y, width: width)
            if case .tmux(let vm) = entry.kind {
                for (idx, w) in vm.windows.enumerated() {
                    addRow(windowRow(session: entry.name, vm: vm, window: w, index: idx),
                           at: &y, width: width)
                }
            }
        }
        // The document view must be at least as tall as the clip view so the
        // sidebar background reads as one continuous surface.
        listView.frame = NSRect(x: 0, y: 0, width: width,
                                height: max(y + 10, scrollView.contentSize.height))
    }

    private func addRow(_ row: SidebarRow, at y: inout CGFloat, width: CGFloat) {
        row.frame = NSRect(x: 8, y: y, width: width - 16, height: SidebarRow.height)
        row.autoresizingMask = [.width]
        listView.addSubview(row)
        y += SidebarRow.height + 2
    }

    private func sessionRow(for entry: Entry) -> SidebarRow {
        let row = SidebarRow()
        // A session row is only the highlighted row when it has no window
        // children to carry the highlight (plain / dormant / not yet listed).
        let selected = entry.name == activeSession && !hasWindowChildren(entry)
        let dot: NSImage
        var dormant = false
        switch entry.kind {
        case .dormant:
            dot = dotImage(.tertiaryLabelColor, style: .ring)
            dormant = true
        case .plain:
            dot = glyphImage("apple.terminal")
        case .tmux(let vm):
            dot = sessionDotImage(vm)
        }
        row.configure(indent: 6, dot: dot, title: entry.name,
                      font: .systemFont(ofSize: 13, weight: .semibold),
                      dormant: dormant, badge: nil, selected: selected)
        let name = entry.name
        row.onClick = { [weak self] in self?.onSelectSession?(name) }
        if case .tmux(let vm) = entry.kind, vm.windows.count > 1 {
            row.menuProvider = { [weak self] in self?.sessionMenu(for: name) }
        }
        return row
    }

    private func hasWindowChildren(_ entry: Entry) -> Bool {
        if case .tmux(let vm) = entry.kind { return !vm.windows.isEmpty }
        return false
    }

    private func windowRow(session: String, vm: TerminalViewModel,
                           window w: SwiftTmux.TmuxWindow, index: Int) -> SidebarRow {
        let row = SidebarRow()
        let paneCount = vm.panes(in: w.id).count
        let selected = session == activeSession && w.id == vm.activeWindowID
        let name = w.name.trimmingCharacters(in: .whitespaces)
        row.configure(indent: 24,
                      dot: dotImage(windowDotColor(vm.windowState(w.id)), style: .filled),
                      title: name.isEmpty ? "window \(index + 1)" : name,
                      font: .systemFont(ofSize: 13),
                      dormant: false,
                      badge: paneCount > 1 ? "\(paneCount)" : nil,
                      selected: selected)
        let windowID = w.id
        row.onClick = { [weak self] in self?.onSelectWindow?(session, windowID) }
        row.menuProvider = { [weak self] in
            self?.windowMenu(session: session, windowID: windowID, canSpread: paneCount > 1)
        }
        return row
    }

    // MARK: - Status dots

    /// Aggregate dot color for a window row (awaiting amber → working green →
    /// idle gray) — the same palette as the pane title-bar dots.
    private func windowDotColor(_ state: PaneState) -> NSColor {
        switch state {
        case .awaitingInput, .working: return state.nsColor
        case .idle:                    return .secondaryLabelColor
        }
    }

    /// Session-level dot, mirroring the tab strip's priority: awaiting →
    /// done-unseen → working → idle.
    private func sessionDotImage(_ vm: TerminalViewModel) -> NSImage {
        if vm.agentsWaiting > 0 { return dotImage(PaneState.awaitingInput(profile: "").nsColor, style: .filled) }
        if vm.agentsDoneUnseen > 0 { return dotImage(PaneTitleBar.doneColor, style: .filled) }
        if vm.agentsWorking > 0 { return dotImage(PaneState.working.nsColor, style: .filled) }
        return dotImage(.secondaryLabelColor, style: .filled)
    }

    private enum DotStyle { case filled, ring }

    /// A filled disc (live) or hollow ring (dormant) — the tab strip's glyphs,
    /// drawn in THIS view's effective appearance so semantic grays resolve to
    /// the right light/dark shade. Rows rebuild on every model tick, so an
    /// appearance flip repaints on the next reload.
    private func dotImage(_ color: NSColor, style: DotStyle, diameter d: CGFloat = 7) -> NSImage {
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        effectiveAppearance.performAsCurrentDrawingAppearance {
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

    /// A small SF Symbol standing in for the dot (the plain-terminal glyph),
    /// tinted to the secondary label color and appearance-resolved.
    private func glyphImage(_ symbol: String) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Terminal")?
            .withSymbolConfiguration(cfg) ?? NSImage()
        let img = NSImage(size: base.size)
        img.lockFocus()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.secondaryLabelColor.set()
            base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // MARK: - Context menus (structure ops)

    /// Carries a window-row's identity through the menu item.
    private struct WindowRef {
        let session: String
        let windowID: TmuxWindowID
    }

    private func windowMenu(session: String, windowID: TmuxWindowID, canSpread: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let spread = NSMenuItem(title: "Spread into Windows",
                                action: #selector(spreadWindowPicked(_:)), keyEquivalent: "")
        spread.target = self
        spread.representedObject = WindowRef(session: session, windowID: windowID)
        spread.isEnabled = canSpread   // a single-pane window has nothing to spread
        menu.addItem(spread)
        return menu
    }

    private func sessionMenu(for session: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let merge = NSMenuItem(title: "Merge into One Window",
                               action: #selector(mergeSessionPicked(_:)), keyEquivalent: "")
        merge.target = self
        merge.representedObject = session
        menu.addItem(merge)
        return menu
    }

    @objc private func spreadWindowPicked(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? WindowRef,
              let vm = viewModel(for: ref.session) else { return }
        // spreadToList acts on the CURRENT window — select it first. The
        // select-window command is queued ahead of spread's refresh on the same
        // control connection, so ordering holds.
        onSelectWindow?(ref.session, ref.windowID)
        Task { await vm.spreadToList() }
    }

    @objc private func mergeSessionPicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let vm = viewModel(for: name) else { return }
        onSelectSession?(name)
        Task { await vm.mergeToTiled() }
    }

    private func viewModel(for session: String) -> TerminalViewModel? {
        for entry in entries where entry.name == session {
            if case .tmux(let vm) = entry.kind { return vm }
        }
        return nil
    }
}

// MARK: - Flipped document view

/// Rows are stacked top-down; NSView's default coordinates are bottom-up.
private final class FlippedListView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - SidebarRow (one clickable line: dot + title + badge)

@MainActor
private final class SidebarRow: NSView {
    static let height: CGFloat = 24

    var onClick: (() -> Void)?
    /// nil (or a nil return) → no context menu for this row.
    var menuProvider: (() -> NSMenu?)?

    private let dotView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")
    private var selected = false
    private var indent: CGFloat = 6
    /// 0 = no badge. Cached so `layout()` can place subviews from the CURRENT
    /// bounds — configure() runs before the row gets its frame, so geometry
    /// can't be computed there.
    private var badgeWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        dotView.imageScaling = .scaleNone
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        badgeField.font = .systemFont(ofSize: 11, weight: .medium)
        badgeField.alignment = .center
        badgeField.wantsLayer = true
        addSubview(dotView)
        addSubview(titleField)
        addSubview(badgeField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(indent: CGFloat, dot: NSImage, title: String, font: NSFont,
                   dormant: Bool, badge: String?, selected: Bool) {
        self.selected = selected
        self.indent = indent
        dotView.image = dot
        titleField.stringValue = title
        titleField.font = font
        // Selected rows sit on the accent fill → white ink; dormant sessions
        // are de-emphasized so loaded ones read as "here".
        titleField.textColor = selected ? .alternateSelectedControlTextColor
                             : dormant  ? .secondaryLabelColor : .labelColor
        badgeField.isHidden = (badge == nil)
        badgeWidth = 0
        if let badge {
            badgeField.stringValue = badge
            badgeField.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            badgeWidth = max(badgeField.intrinsicContentSize.width + 10, 18)
            // CGColor is a static snapshot — resolve in the current appearance.
            // Rows rebuild on every model tick, so a theme flip catches up fast.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                badgeField.layer?.backgroundColor = selected
                    ? NSColor.white.withAlphaComponent(0.22).cgColor
                    : NSColor.labelColor.withAlphaComponent(0.10).cgColor
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        dotView.frame = NSRect(x: indent, y: 0, width: 16, height: Self.height)
        var trailing: CGFloat = 6
        if badgeWidth > 0 {
            let h: CGFloat = 15
            badgeField.frame = NSRect(x: bounds.width - badgeWidth - 6,
                                      y: (Self.height - h) / 2, width: badgeWidth, height: h)
            badgeField.layer?.cornerRadius = h / 2
            trailing = badgeWidth + 12
        }
        let x = indent + 20
        titleField.frame = NSRect(x: x, y: (Self.height - 17) / 2,
                                  width: max(0, bounds.width - x - trailing), height: 17)
    }

    // Layer-backed selection fill: updateLayer keeps the accent color resolving
    // against the row's live appearance (a bare cgColor snapshot wouldn't).
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected
                ? NSColor.selectedContentBackgroundColor.cgColor
                : NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
#endif
