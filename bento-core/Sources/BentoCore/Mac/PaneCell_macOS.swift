#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - Pane container (title bar + terminal surface)

/// Phase of a title-bar drag used for drag-to-dock. Points are in window
/// coordinates; the host converts and hit-tests against its cells.
enum PaneDragPhase {
    case moved(NSPoint)
    case ended(NSPoint)
}

/// The translucent landing preview shown while a pane drag hovers a target:
/// the whole pane for a center/swap drop (with a ⇄ badge — the one zone whose
/// meaning isn't its own shape), the docked half for an edge drop. Hit-test
/// transparent; the title-bar drag owns the mouse anyway.
@MainActor
final class PaneDropZoneOverlay: NSView {
    private let icon = NSImageView()

    var zone: PaneDropZone = .center {
        didSet {
            guard oldValue != zone else { return }
            icon.isHidden = (zone != .center)
        }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let accent = PaneChromeColors.focusAccent()
        layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        layer?.borderColor = accent.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        icon.image = NSImage(systemSymbolName: "rectangle.2.swap",
                             accessibilityDescription: "Swap panes")?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .medium))
        icon.contentTintColor = accent
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        icon.sizeToFit()
        icon.frame.origin = NSPoint(x: (bounds.width - icon.frame.width) / 2,
                                    y: (bounds.height - icon.frame.height) / 2)
    }
}

/// A passive color wash over the pane content that signals pane state
/// (working / awaiting / done). Hit-test transparent so it never steals mouse
/// events from the surface — selection, link clicks, and title-bar drag-to-swap
/// all keep working underneath it.
@MainActor
final class PaneStateTintView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class PaneCellView: NSView {
    var onClick: (() -> Void)?
    /// Fired while the title bar is dragged beyond the click slop — the
    /// drag-to-dock gesture. Clicks under the threshold stay clicks.
    var onPaneDrag: ((PaneDragPhase) -> Void)?
    var onZoom: (() -> Void)? {
        didSet { titleBar.onZoom = onZoom }
    }
    var onMenu: (() -> Void)? {
        didSet { titleBar.onMenu = onMenu }
    }
    var onNewChat: (() -> Void)? {
        didSet { titleBar.onNewChat = onNewChat }
    }
    var onShowHistory: (() -> Void)? {
        didSet { titleBar.onShowHistory = onShowHistory }
    }
    private let titleBar = PaneTitleBar()
    private let stateTint = PaneStateTintView()
    private weak var surface: NSView?

    /// Title-strip height (points). Set to one character cell so the strip fits
    /// exactly in the layout's divider row between stacked panes (see the host's native
    /// layout). The host updates it as the font/cell size changes.
    var titleBarHeight: CGFloat = 20 {
        didSet { needsLayout = true }
    }

    /// Horizontal inset (points) of the surface inside the container. The host
    /// grows each container half a cell into the divider column on each side so
    /// adjacent panes meet (and their borders/highlight land) on the divider
    /// centerline — no visible gap. The surface stays at its exact cell size,
    /// inset by this much so its content keeps its true position.
    var surfaceInsetX: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    /// The button the per-pane menu should anchor to.
    var menuButtonAnchor: NSView { titleBar.menuButton }
    /// The button the history menu should anchor to.
    var historyButtonAnchor: NSView { titleBar.historyButton }

    var title: String = "" {
        didSet { titleBar.text = title }
    }

    var paneState: PaneState = .idle {
        didSet { titleBar.paneState = paneState; updateStateTint(); applyBorder() }
    }

    var agentFinishedUnseen: Bool = false {
        didSet { titleBar.agentFinishedUnseen = agentFinishedUnseen; updateStateTint(); applyBorder() }
    }

    /// Translucent wash over the surface that mirrors the title-bar dot:
    /// done-unseen → blue, otherwise the per-state color (nil = idle = no wash).
    private func stateTintColor() -> NSColor? {
        if agentFinishedUnseen {
            return PaneTitleBar.doneColor.withAlphaComponent(0.10)
        }
        return paneState.tintNSColor
    }

    private func updateStateTint() {
        let cg = stateTintColor()?.cgColor
        // Cross-fade so state changes don't pop. AppKit disables implicit
        // animations on layer-backed views, so add the transition explicitly;
        // with no fromValue it animates from the current presentation color.
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.duration = 0.25
        stateTint.layer?.add(anim, forKey: "tint")
        stateTint.layer?.backgroundColor = cg
    }

    var isActivePane: Bool = false {
        didSet {
            applyBorder()
            titleBar.isActive = isActivePane
        }
    }

    /// When only one pane is on screen (a single pane, or a zoomed pane), there's
    /// nothing to disambiguate — hide the focus border so it isn't just noise.
    var focusSuppressed: Bool = false {
        didSet {
            guard oldValue != focusSuppressed else { return }
            applyBorder()
        }
    }

    private func applyBorder() {
        // The border is purely the FOCUS cue: the window highlight color on the
        // pane you're interacting with, a near-invisible hairline on the rest.
        // Suppressed when there's only one pane visible (nothing to focus).
        // Agent state stays on the title bar + status dot + body wash, so the
        // focus ring never competes with green/amber/blue. (Drop targets are
        // previewed by the host's PaneDropZoneOverlay, not the border.)
        let showFocus = isActivePane && !focusSuppressed
        layer?.borderWidth = showFocus ? 2.0 : 0.5
        let color = PaneChromeColors.focusBorder(active: showFocus)
        // Resolve the dynamic accent against this view's light/dark appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = color.cgColor
        }
    }

    /// Re-derive every appearance-dependent CGColor (border + title-bar band/ink).
    /// CGColors are static snapshots, so this must run on a light/dark flip.
    func recolorChrome() {
        applyBorder()
        titleBar.recolorChrome()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Clip to the container in case the surface rounds a fraction of a pixel
        // past the edge.
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = PaneChromeColors.neutralHairline().cgColor
        addSubview(titleBar)

        // State wash sits above the terminal surface (added in `embed`) but below
        // the title bar, so the dot + label stay crisp while the terminal body
        // takes the tint. Hit-test transparent (see PaneStateTintView).
        stateTint.wantsLayer = true
        addSubview(stateTint, positioned: .below, relativeTo: titleBar)
        updateStateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func embed(_ view: NSView) {
        surface = view
        // Keep the surface beneath the state wash so the tint overlays the
        // terminal content (not the other way around).
        addSubview(view, positioned: .below, relativeTo: stateTint)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = titleBarHeight
        titleBar.isHidden = (h <= 0)   // Focus mode: no pane chrome at all
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        // The surface keeps its exact cell size (= bounds minus the half-cell the
        // host added on each side, and minus the title bar), inset by surfaceInsetX
        // so its content stays put while the container reaches the divider midline.
        let surfaceRect = NSRect(x: surfaceInsetX, y: h,
                                 width: max(bounds.width - 2 * surfaceInsetX, 0),
                                 height: max(bounds.height - h, 0))
        surface?.frame = surfaceRect
        stateTint.frame = surfaceRect
    }

    // MARK: Title-bar drag (drag-to-swap)
    //
    // Mouse events only reach this view from the title bar (minus its buttons)
    // and the thin border slivers — the surface subview consumes everything
    // else — so a drag here is unambiguously "drag the pane", never text
    // selection or divider resize.
    private var dragPending = false
    private var dragActive = false
    private var dragStart: NSPoint = .zero
    private static let dragSlop: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        onClick?()
        dragPending = true
        dragActive = false
        dragStart = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragPending else {
            super.mouseDragged(with: event)
            return
        }
        let p = event.locationInWindow
        if !dragActive, hypot(p.x - dragStart.x, p.y - dragStart.y) > Self.dragSlop {
            dragActive = true
        }
        if dragActive {
            onPaneDrag?(.moved(p))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragActive {
            onPaneDrag?(.ended(event.locationInWindow))
        }
        dragPending = false
        dragActive = false
        super.mouseUp(with: event)
    }
}

/// The thin label strip atop each pane, with zoom + menu buttons on the right.
@MainActor
final class PaneTitleBar: NSView {
    private let label = NSTextField(labelWithString: "")
    /// Leading semantic state glyph (the same play/question/check language as the
    /// List sidebar), replacing the old status dot. Empty for idle.
    private let stateIcon = NSImageView()
    let zoomButton = NSButton()
    let menuButton = NSButton()
    /// Start a fresh conversation in this pane (current one graduates to history).
    let newChatButton = NSButton()
    /// Recent-conversation menu (popped up as an NSMenu by the host).
    let historyButton = NSButton()
    var onZoom: (() -> Void)?
    var onMenu: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onShowHistory: (() -> Void)?

    var text: String = "" {
        didSet { label.stringValue = text }
    }

    /// Pane working/idle/awaiting — drives the leading state glyph (play/question)
    /// and the title-bar band color (blue / amber / green).
    var paneState: PaneState = .idle {
        didSet { updateStateIcon(); updateChrome() }
    }

    /// A coding-agent pane that finished but hasn't been looked at → "done"
    /// (green ✓ glyph + green band), distinct from a plain idle/seen pane.
    var agentFinishedUnseen: Bool = false {
        didSet { updateStateIcon(); updateChrome() }
    }

    /// "Done, unseen" green (a finished ✓). Also drives the pane's state wash +
    /// band (see PaneCellView.stateTintColor / chromeAccent). Sourced from the
    /// shared palette so the List sidebar's green check matches.
    static let doneColor = PaneState.nsColor(hex: PaneState.doneUnseenHex)

    /// The leading glyph + tint for the current state. Same mapping as the List
    /// sidebar: working = play, awaiting = question, done-unseen = check, idle =
    /// a quiet hollow gray ring (same `.circle` family, empty = at rest).
    /// Colored from the shared palette.
    private func stateSymbol() -> (name: String, color: NSColor) {
        if agentFinishedUnseen { return ("checkmark.circle.fill", Self.doneColor) }
        switch paneState {
        case .working:       return ("play.circle.fill", paneState.nsColor)
        case .awaitingInput: return ("questionmark.circle.fill", paneState.nsColor)
        case .idle:          return ("circle", PaneState.nsColor(hex: PaneState.idleHex))
        }
    }

    private func updateStateIcon() {
        let (name, color) = stateSymbol()
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        stateIcon.image = img
        stateIcon.contentTintColor = color
    }

    /// Accent for the band/ink: done-unseen wins (blue), otherwise the per-state
    /// color (nil for idle → neutral chrome).
    private func chromeAccent() -> NSColor? {
        agentFinishedUnseen ? Self.doneColor : paneState.chromeAccentNSColor
    }

    /// Recompute the band background + label/button ink from (state, active).
    private func updateChrome() {
        // Agent state wins the band color; otherwise a focused-but-idle pane takes
        // the window highlight color, so focus reads from the title bar too — not
        // just the border (the border alone is too quiet for an idle gray pane).
        let accent = chromeAccent() ?? (isActive ? PaneChromeColors.focusAccent() : nil)
        layer?.backgroundColor = PaneChromeColors.titleBand(accent: accent, active: isActive).cgColor
        let ink = PaneChromeColors.ink(accent: accent, active: isActive)
        label.textColor = ink
        zoomButton.contentTintColor = ink
        menuButton.contentTintColor = ink
        newChatButton.contentTintColor = ink
        historyButton.contentTintColor = ink
    }

    /// Re-derive the band/ink CGColors on a light/dark flip (see PaneCellView).
    func recolorChrome() { updateChrome() }

    var isActive: Bool = false {
        didSet { updateChrome() }
    }

    /// Square hit target for each title-bar button.
    private static let buttonSize: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PaneChromeColors.titleBand(accent: nil, active: false).cgColor

        stateIcon.imageScaling = .scaleProportionallyUpOrDown
        updateStateIcon()
        addSubview(stateIcon)

        configure(newChatButton, symbol: "plus.bubble", fallback: "+",
                  action: #selector(newChatTapped), tooltip: "New Chat")
        configure(historyButton, symbol: "clock.arrow.circlepath", fallback: "⌚",
                  action: #selector(historyTapped), tooltip: "Resume a Past Conversation")
        configure(zoomButton, symbol: "arrow.up.left.and.arrow.down.right",
                  fallback: "⤢", action: #selector(zoomTapped), tooltip: "Toggle Zoom")
        configure(menuButton, symbol: "ellipsis", fallback: "⋯",
                  action: #selector(menuTapped), tooltip: "Pane Menu")

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.65, alpha: 1.0)
        label.lineBreakMode = .byTruncatingTail
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        updateChrome()
    }

    /// Manual layout (the bar's own frame is set by the parent), so the buttons
    /// sit at a fixed size flush-right and never depend on intrinsic sizes.
    /// Order right→left: menu, zoom, history, new.
    override func layout() {
        super.layout()
        let s = Self.buttonSize
        let pad: CGFloat = 6
        let gap: CGFloat = 4
        let y = ((bounds.height - s) / 2).rounded()
        let menuX = bounds.width - pad - s
        let zoomX = menuX - gap - s
        let historyX = zoomX - gap - s
        let newX = historyX - gap - s
        menuButton.frame = NSRect(x: menuX, y: y, width: s, height: s)
        zoomButton.frame = NSRect(x: zoomX, y: y, width: s, height: s)
        historyButton.frame = NSRect(x: historyX, y: y, width: s, height: s)
        newChatButton.frame = NSRect(x: newX, y: y, width: s, height: s)
        let chromeLeftX = newX
        // Fixed-width leading slot for the state glyph, so the title never shifts
        // as state changes (idle = empty slot, same x for the label).
        let icon: CGFloat = 16
        stateIcon.frame = NSRect(x: pad, y: ((bounds.height - icon) / 2).rounded(), width: icon, height: icon)
        let labelX = stateIcon.frame.maxX + 6
        let labelRight = chromeLeftX - pad
        // Center the label on its line height (a full-height NSTextField frame
        // top-aligns the glyphs, which looks off in a one-cell-tall strip).
        let font = label.font ?? .systemFont(ofSize: 12, weight: .medium)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let labelY = ((bounds.height - lineH) / 2).rounded()
        label.frame = NSRect(x: labelX, y: labelY, width: max(labelRight - labelX, 0), height: lineH)
    }

    private func configure(_ button: NSButton, symbol: String, fallback: String,
                           action: Selector, tooltip: String) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.contentTintColor = NSColor(white: 0.65, alpha: 1.0)
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            button.image = img
        } else {
            button.imagePosition = .noImage
            button.title = fallback
            button.font = .systemFont(ofSize: 12)
        }
        addSubview(button)
    }

    @objc private func zoomTapped() { onZoom?() }
    @objc private func menuTapped() { onMenu?() }
    @objc private func newChatTapped() { onNewChat?() }
    @objc private func historyTapped() { onShowHistory?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // Let the buttons receive clicks, but everything else falls through to the
    // pane container (so clicking the title to focus the pane still works).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        let buttons: [NSView] = [zoomButton, menuButton, newChatButton, historyButton]
        return buttons.contains(where: { $0 === hit }) ? hit : nil
    }
}

@MainActor
enum PaneChromeColors {
    static let accentNSColor = NSColor(srgbRed: 0.30, green: 0.90, blue: 0.62, alpha: 1.0)

    private static let srgbWhite = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let srgbBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// The light/dark the chrome should paint for. Read once per recolor pass.
    static var isDark: Bool { ThemeStore.shared.effectiveIsDark }

    /// Title-bar band for a state accent (nil = idle → neutral). Active panes get
    /// a brighter/heavier band so focus reads within one state color. Dark mode =
    /// dark band; light mode = light band, with colored accents tinted to match.
    static func titleBand(accent: NSColor?, active: Bool) -> NSColor {
        guard let a = accent else {
            return isDark ? NSColor(white: active ? 0.16 : 0.12, alpha: 1)
                          : NSColor(white: active ? 0.86 : 0.92, alpha: 1)
        }
        return isDark ? a.darkened(to: active ? 0.30 : 0.17)
                      : a.lightened(to: active ? 0.74 : 0.86)
    }

    /// Label / button ink over the band: muted when inactive, a tint of the accent
    /// when active. Light text on the dark band; dark text on the light band.
    static func ink(accent: NSColor?, active: Bool) -> NSColor {
        if isDark {
            guard active else { return NSColor(white: 0.62, alpha: 1) }
            guard let a = accent else { return NSColor(white: 0.95, alpha: 1) }
            return a.blended(withFraction: 0.45, of: srgbWhite) ?? a
        } else {
            guard active else { return NSColor(white: 0.42, alpha: 1) }
            guard let a = accent else { return NSColor(white: 0.16, alpha: 1) }
            return a.blended(withFraction: 0.55, of: srgbBlack) ?? a
        }
    }

    /// The system/window highlight color (the user's macOS accent) as a concrete
    /// sRGB color — the focus color for the active pane's border + title band.
    static func focusAccent() -> NSColor {
        NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accentNSColor
    }

    /// Focus outline for the pane border: the window highlight color on the active
    /// pane, a near-invisible hairline otherwise — so the focused tile reads at a
    /// glance regardless of its agent state (which the title bar / dot / wash carry).
    static func focusBorder(active: Bool) -> NSColor {
        if active { return focusAccent() }
        return isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.09)
    }

    /// Neutral hairline for the title-bar default before chrome is computed.
    static func neutralHairline() -> NSColor {
        isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.14)
    }
}

private extension NSColor {
    /// Multiply RGB toward black by `factor` (0…1), preserving alpha. Works in
    /// sRGB so the result is predictable regardless of the source color space.
    func darkened(to factor: CGFloat) -> NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        return NSColor(srgbRed: c.redComponent * factor,
                       green: c.greenComponent * factor,
                       blue: c.blueComponent * factor,
                       alpha: c.alphaComponent)
    }

    /// Mix RGB toward white by `amount` (0…1), preserving alpha — the light-mode
    /// analog of `darkened(to:)` for tinting a colored band on a light surface.
    func lightened(to amount: CGFloat) -> NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        return NSColor(srgbRed: c.redComponent + (1 - c.redComponent) * amount,
                       green: c.greenComponent + (1 - c.greenComponent) * amount,
                       blue: c.blueComponent + (1 - c.blueComponent) * amount,
                       alpha: c.alphaComponent)
    }
}

#endif
