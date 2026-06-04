#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftTmux

/// Stacks a tmux window-tab strip above the tiled pane host. The strip is shown
/// only when the session has more than one window (iTerm2 hides a lone tab), so
/// a single-window session looks exactly as before.
@MainActor
final class TerminalWindowContent: NSView {
    let tabBar = WindowTabBar()
    let host: GhosttyTiledPaneHost
    private static let tabBarHeight: CGFloat = 28
    private var showsTabBar = false

    init(host: GhosttyTiledPaneHost) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        autoresizesSubviews = true
        // Autoresizing guarantees the host's `setFrameSize` (hence `layout()`,
        // hence the tmux client resize) fires on every window resize even if the
        // container's own `layout()` is skipped. `layout()` below then corrects
        // the exact frames (e.g. the tab-bar inset). Belt and suspenders.
        host.autoresizingMask = [.width, .height]
        tabBar.autoresizingMask = [.width]
        addSubview(tabBar)
        addSubview(host)
        tabBar.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Refresh the tab strip from the VM's window list + active window.
    func update(windows: [TmuxWindow], activeID: TmuxWindowID?) {
        tabBar.update(windows: windows, activeID: activeID)
        let shows = windows.count > 1
        if shows != showsTabBar {
            showsTabBar = shows
            tabBar.isHidden = !shows
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let h = showsTabBar ? Self.tabBarHeight : 0
        tabBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        let hostFrame = NSRect(x: 0, y: h, width: bounds.width, height: max(bounds.height - h, 0))
        if host.frame != hostFrame { host.frame = hostFrame }
        // Force the host (and its panes/surfaces) to lay out now so the tmux
        // client size tracks the window even when AppKit folds the resize into a
        // single pass.
        host.layoutSubtreeIfNeeded()
    }
}

/// A horizontal strip of tmux window tabs with a trailing "+" (new window).
/// Clean modern chrome (not a terminal-cosplay strip): a dark bar, the active
/// tab tinted with the Bento accent. Click a tab → `onSelect`; "+" → `onNew`.
@MainActor
public final class WindowTabBar: NSView {
    var onSelect: ((TmuxWindowID) -> Void)?
    var onNew: (() -> Void)?

    private var tabs: [(id: TmuxWindowID, button: NSButton)] = []
    private var activeID: TmuxWindowID?
    private let newButton = NSButton()

    private static let height: CGFloat = 28
    private static let minTabWidth: CGFloat = 72
    private static let maxTabWidth: CGFloat = 180
    private static let newButtonWidth: CGFloat = 28

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.09, alpha: 1.0).cgColor

        newButton.isBordered = false
        newButton.bezelStyle = .regularSquare
        newButton.imagePosition = .imageOnly
        newButton.setButtonType(.momentaryChange)
        newButton.target = self
        newButton.action = #selector(newTapped)
        newButton.contentTintColor = NSColor(white: 0.7, alpha: 1.0)
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        if let img = NSImage(systemSymbolName: "plus", accessibilityDescription: "New window")?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            newButton.image = img
        } else {
            newButton.imagePosition = .noImage
            newButton.title = "+"
        }
        addSubview(newButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    func update(windows: [SwiftTmux.TmuxWindow], activeID: TmuxWindowID?) {
        self.activeID = activeID
        let ids = windows.map(\.id)
        if ids != tabs.map(\.id) {
            // Window set changed — rebuild the buttons.
            tabs.forEach { $0.button.removeFromSuperview() }
            tabs = windows.enumerated().map { idx, w in
                let b = makeTabButton(title: tabTitle(w, index: idx), tag: idx)
                addSubview(b)
                return (w.id, b)
            }
        } else {
            // Same windows — just refresh titles (renames).
            for (idx, w) in windows.enumerated() {
                tabs[idx].button.title = tabTitle(w, index: idx)
            }
        }
        restyle()
        needsLayout = true
    }

    private func tabTitle(_ w: SwiftTmux.TmuxWindow, index: Int) -> String {
        let name = w.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "\(index + 1)" : "\(index + 1): \(name)"
    }

    private func makeTabButton(title: String, tag: Int) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(tabTapped(_:)))
        b.tag = tag
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.setButtonType(.momentaryChange)
        b.font = .systemFont(ofSize: 11, weight: .medium)
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        b.lineBreakMode = .byTruncatingTail
        (b.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        return b
    }

    private func restyle() {
        for (id, button) in tabs {
            let isActive = (id == activeID)
            button.layer?.backgroundColor = isActive
                ? NSColor(srgbRed: 0.12, green: 0.26, blue: 0.20, alpha: 1.0).cgColor
                : NSColor(white: 0.16, alpha: 1.0).cgColor
            button.contentTintColor = isActive
                ? GhosttyPaneColors.accentNSColor
                : NSColor(white: 0.7, alpha: 1.0)
            let color: NSColor = isActive ? GhosttyPaneColors.accentNSColor : NSColor(white: 0.7, alpha: 1.0)
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [.foregroundColor: color,
                             .font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        }
    }

    public override func layout() {
        super.layout()
        let pad: CGFloat = 6
        let gap: CGFloat = 4
        var x = pad
        let avail = bounds.width - pad * 2 - Self.newButtonWidth - gap
        // Equal-share tab widths, clamped, so many windows still fit.
        let count = max(tabs.count, 1)
        let share = (avail - gap * CGFloat(count - 1)) / CGFloat(count)
        let tabW = min(max(share, Self.minTabWidth), Self.maxTabWidth)
        let y: CGFloat = 3
        let h = Self.height - 6
        for (_, button) in tabs {
            button.frame = NSRect(x: x, y: y, width: tabW, height: h)
            x += tabW + gap
        }
        newButton.frame = NSRect(x: x + 2, y: y, width: Self.newButtonWidth, height: h)
    }

    @objc private func tabTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < tabs.count else { return }
        onSelect?(tabs[sender.tag].id)
    }

    @objc private func newTapped() { onNew?() }
}
#endif
