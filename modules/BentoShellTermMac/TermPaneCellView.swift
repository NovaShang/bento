#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoWorkbench

/// One tiled pane's container: a slim title strip (state dot · title · focus ·
/// close) over the embedded terminal surface, with an accent border when it is
/// the active pane. The product-B twin of BentoShellMac's `PaneCellView`, kept
/// deliberately lean (no scroll-bookmark chevrons / mode badge yet — flagged in
/// the port notes; the daemon mirror doesn't carry copy-mode/mouse state).
@MainActor
final class TermPaneCellView: NSView {
    // Callbacks the host wires.
    var onClick: (() -> Void)?
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?
    var onPaneDrag: ((PaneDragPhase) -> Void)?

    /// 0 hides the strip (Focus mode — the single pane owns the whole cell).
    var titleBarHeight: CGFloat = 22 { didSet { needsLayout = true } }
    /// Hairline gutter kept between side-by-side surfaces.
    var surfaceInsetX: CGFloat = 0 { didSet { needsLayout = true } }

    var title: String = "" { didSet { titleField.stringValue = title } }
    var status: PaneDisplayStatus = .idle { didSet { recolor() } }
    var isActivePane = false { didSet { recolor() } }
    /// One visible pane → nothing to disambiguate, so the border is suppressed.
    var focusSuppressed = false { didSet { recolor() } }

    private let titleBar = NSView()
    private let dot = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let focusButton = NSButton()
    private let closeButton = NSButton()
    private var surface: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        layer?.masksToBounds = true

        titleBar.wantsLayer = true
        addSubview(titleBar)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        titleBar.addSubview(dot)

        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = .secondaryLabelColor
        titleBar.addSubview(titleField)

        configureButton(focusButton, symbol: "arrow.up.left.and.arrow.down.right",
                        action: #selector(focusTapped))
        focusButton.toolTip = "Focus this pane"
        titleBar.addSubview(focusButton)

        configureButton(closeButton, symbol: "xmark", action: #selector(closeTapped))
        closeButton.toolTip = "Close pane"
        titleBar.addSubview(closeButton)

        let click = NSClickGestureRecognizer(target: self, action: #selector(barClicked))
        titleBar.addGestureRecognizer(click)
        let pan = NSPanGestureRecognizer(target: self, action: #selector(barDragged(_:)))
        titleBar.addGestureRecognizer(pan)
        recolor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func configureButton(_ b: NSButton, symbol: String, action: Selector) {
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = .secondaryLabelColor
        b.target = self
        b.action = action
    }

    /// Embed the pane's terminal surface below the title strip.
    func embed(_ view: NSView) {
        surface?.removeFromSuperview()
        surface = view
        view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(view, positioned: .below, relativeTo: titleBar)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        titleBar.frame = NSRect(x: 0, y: 0, width: b.width, height: titleBarHeight)
        titleBar.isHidden = titleBarHeight <= 0
        let inset: CGFloat = 6
        dot.frame = NSRect(x: inset, y: (titleBarHeight - 7) / 2, width: 7, height: 7)
        let btnSize: CGFloat = titleBarHeight
        closeButton.frame = NSRect(x: b.width - btnSize, y: 0, width: btnSize, height: titleBarHeight)
        focusButton.frame = NSRect(x: b.width - btnSize * 2, y: 0, width: btnSize, height: titleBarHeight)
        let textX = dot.frame.maxX + 6
        titleField.frame = NSRect(x: textX, y: 0, width: max(focusButton.frame.minX - textX - 4, 0),
                                  height: titleBarHeight)

        surface?.frame = NSRect(
            x: surfaceInsetX, y: titleBarHeight,
            width: max(b.width - surfaceInsetX * 2, 0),
            height: max(b.height - titleBarHeight, 0))
    }

    private func recolor() {
        let accent = TermColors.status(status)
        dot.layer?.backgroundColor = accent.cgColor
        let showBorder = isActivePane && !focusSuppressed
        layer?.borderColor = (showBorder ? TermColors.activeBorder : TermColors.idleBorder).cgColor
        titleBar.layer?.backgroundColor = TermColors.titleBar(active: showBorder).cgColor
        titleField.textColor = showBorder ? .labelColor : .secondaryLabelColor
    }

    // MARK: Gestures

    @objc private func barClicked() { onClick?() }
    @objc private func focusTapped() { onFocus?() }
    @objc private func closeTapped() { onClose?() }

    private var dragging = false
    @objc private func barDragged(_ g: NSPanGestureRecognizer) {
        guard let window else { return }
        let screen = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screen)
        switch g.state {
        case .changed:
            dragging = true
            onPaneDrag?(.moved(windowPoint))
        case .ended, .cancelled, .failed:
            if dragging { onPaneDrag?(.ended(windowPoint)) }
            dragging = false
        default:
            break
        }
    }
}

/// Drag phases the title-bar pan reports to the host (window coordinates).
enum PaneDragPhase {
    case moved(NSPoint)
    case ended(NSPoint)
}

/// The product-B chrome palette, kept self-contained (no cross-module color
/// coupling): the PaneState hexes shared across the app (docs/…PaneState).
enum TermColors {
    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static let working = rgb(0x0A85FF)     // blue
    static let awaiting = rgb(0xFF9F0A)    // amber
    static let doneUnseen = rgb(0x30D158)  // green
    static let idle = rgb(0x8E8E93)        // gray

    static func status(_ s: PaneDisplayStatus) -> NSColor {
        switch s {
        case .working: return working
        case .awaiting: return awaiting
        case .doneUnseen: return doneUnseen
        case .idle: return idle
        }
    }
    static let activeBorder = working.withAlphaComponent(0.9)
    static let idleBorder = NSColor.separatorColor
    static func titleBar(active: Bool) -> NSColor {
        active ? working.withAlphaComponent(0.12) : NSColor.textBackgroundColor.withAlphaComponent(0.4)
    }
}
#endif
