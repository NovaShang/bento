import UIKit
import BentoCore

/// Phases of a pane title-bar drag (tiled mode), reported to the parent so it
/// can resolve the pane + drop zone under the finger (center = swap, edge =
/// dock). Points are in WINDOW coordinates (`gesture.location(in: nil)`) so
/// the parent can hit-test across all panes. Mirrors the macOS host's
/// `PaneDragPhase`.
enum TitleDragPhase {
    case began
    case moved(CGPoint)
    case ended(CGPoint)
    case cancelled
}

/// The title bar sitting atop a pane — the iOS twin of the macOS
/// `PaneTitleBar`: the same leading state glyph (play / question / check /
/// hollow ring), the same title, and the same trailing controls (new chat,
/// focus this pane, pane menu). Two looks:
///   • Tiled (multi-pane): a state-tinted band, brightening when active
///     (mirrors the macOS host's chrome).
///   • Single / focus: blends into the pane background (no contrast band),
///     so a fullscreen pane reads as one continuous surface.
///
/// Layout: [◉ state] [title………………………] [＋] [▣] [⋯]
final class PaneTitleBar: UIView {
    let titleLabel = UILabel()
    /// Leading semantic state glyph — the SAME symbol language as the macOS
    /// pane chrome and the shared `PaneSidebar` rows, not a bare dot.
    private let stateIcon = UIImageView()

    /// Start a fresh conversation in this pane (the current one graduates to
    /// history) — macOS's `plus.bubble` title-bar button.
    let newChatButton = UIButton(type: .system)
    /// Show this pane alone (switch the workspace to Focus on it).
    let focusButton = UIButton(type: .system)
    /// The per-pane ⋯ menu. The host attaches a `UIMenu` (built fresh per open),
    /// so this button needs no action target.
    let menuButton = UIButton(type: .system)

    var onNewChat: (() -> Void)?
    var onFocus: (() -> Void)?

    /// Drives the glyph, the title-bar band color, and (when active) text emphasis.
    var paneState: PaneState = .idle {
        didSet { updateStateVisuals(); updateChrome() }
    }

    /// An agent that finished while you were looking elsewhere → the green ✓,
    /// a display state that sits beside `paneState` rather than inside it
    /// (same split as the macOS chrome and `PaneDisplayStatus`).
    var agentFinishedUnseen: Bool = false {
        didSet {
            guard oldValue != agentFinishedUnseen else { return }
            updateStateVisuals(); updateChrome()
        }
    }

    /// Active state drives the band chrome (tiled) / text emphasis (blend).
    var isActivePane: Bool = false {
        didSet { updateChrome() }
    }

    /// Tiled mode → macOS-style band chrome; otherwise blend into the
    /// pane background (`surfaceColor`). Focus has nothing left to focus, so
    /// the focus button hides there.
    var isTiled: Bool = false {
        didSet {
            guard oldValue != isTiled else { return }
            focusButton.isHidden = !isTiled
            updateChrome()
            setNeedsLayout()
        }
    }

    /// Pane background, used only in blend (non-tiled) mode so a fullscreen
    /// pane's title bar flows into the content. Ignored in tiled mode.
    var surfaceColor: UIColor = STTheme.term.bg {
        didSet { if !isTiled { backgroundColor = surfaceColor } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // In tiled mode the strip is short; clip so the centered glyph never
        // spills onto the content below.
        clipsToBounds = true

        stateIcon.contentMode = .scaleAspectFit
        addSubview(stateIcon)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = "agent"
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        configure(newChatButton, symbol: "plus.bubble", label: "New Chat")
        newChatButton.addTarget(self, action: #selector(newChatTapped), for: .touchUpInside)
        configure(focusButton, symbol: "rectangle.inset.filled", label: "Focus This Pane")
        focusButton.addTarget(self, action: #selector(focusTapped), for: .touchUpInside)
        configure(menuButton, symbol: "ellipsis", label: "Pane Menu")
        // The host hands over a freshly built menu; opening it IS the tap.
        menuButton.showsMenuAsPrimaryAction = true
        focusButton.isHidden = !isTiled

        updateStateVisuals()
        updateChrome()
    }

    private func configure(_ button: UIButton, symbol: String, label: String) {
        button.setImage(UIImage(systemName: symbol, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        button.accessibilityLabel = label
        addSubview(button)
    }

    @objc private func newChatTapped() { onNewChat?() }
    @objc private func focusTapped() { onFocus?() }

    /// Manual layout (the bar's frame is set by the pane VC), so the controls sit
    /// at a fixed touch size flush-right and never depend on intrinsic sizes.
    /// Order right→left: menu, focus, new chat — the same as macOS.
    override func layoutSubviews() {
        super.layoutSubviews()
        let s = Self.buttonSize
        let pad: CGFloat = 8
        let gap: CGFloat = 2
        let y = ((bounds.height - s) / 2).rounded()
        var x = bounds.width - pad - s
        for button in [menuButton, focusButton, newChatButton] where !button.isHidden {
            button.frame = CGRect(x: x, y: y, width: s, height: s)
            x -= (s + gap)
        }
        // Fixed-width leading slot for the glyph, so the title never shifts as
        // state changes (idle keeps the same x for the label).
        let icon: CGFloat = 16
        stateIcon.frame = CGRect(x: 12, y: ((bounds.height - icon) / 2).rounded(),
                                 width: icon, height: icon)
        let labelX = stateIcon.frame.maxX + 8
        // `x` now points just left of the leftmost visible button.
        let labelRight = x + s - gap - pad
        titleLabel.frame = CGRect(x: labelX, y: 0,
                                  width: max(labelRight - labelX, 0), height: bounds.height)
    }

    /// Square hit target for each title-bar button.
    private static let buttonSize: CGFloat = 28

    /// Tiled: band + text track the pane state (blue / amber / green, neutral
    /// for idle), brightening when active — mirrors the macOS host. Blend
    /// (focus / single pane): the title bar flows into the pane background,
    /// text brightens only when active.
    private func updateChrome() {
        let ink: UIColor
        if isTiled {
            let accent = chromeAccent
            backgroundColor = STTheme.titleBand(accent: accent, active: isActivePane)
            ink = STTheme.titleInk(accent: accent, active: isActivePane)
        } else {
            backgroundColor = surfaceColor
            ink = isActivePane ? .label : .secondaryLabel
        }
        titleLabel.textColor = ink
        for button in [newChatButton, focusButton, menuButton] { button.tintColor = ink }
    }

    /// Band accent: done-unseen wins (green), else the per-state color (nil for
    /// idle → neutral chrome). Same precedence as the macOS chrome.
    private var chromeAccent: UIColor? {
        if agentFinishedUnseen { return PaneState.uiColor(hex: PaneState.doneUnseenHex) }
        return paneState.chromeAccentUIColor
    }

    /// Re-derive the band/ink for the current appearance (the band colors are
    /// resolved at compute time, not trait-reactive UIColors).
    func recolor() { updateChrome() }

    /// The leading glyph for the current state — identical mapping to the macOS
    /// title bar and the shared sidebar rows: working = blue play, awaiting =
    /// amber question, done-unseen = green check, idle = a quiet hollow gray
    /// ring (same `.circle` family, empty = at rest).
    private func updateStateVisuals() {
        let (symbol, hex): (String, UInt32) = {
            if agentFinishedUnseen { return ("checkmark.circle.fill", PaneState.doneUnseenHex) }
            switch paneState {
            case .working:       return ("play.circle.fill", PaneState.workingHex)
            case .awaitingInput: return ("questionmark.circle.fill", PaneState.awaitingHex)
            case .idle:          return ("circle", PaneState.idleHex)
            }
        }()
        let color = PaneState.uiColor(hex: hex)
        stateIcon.image = UIImage(systemName: symbol, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        stateIcon.tintColor = color

        // A pending question / running turn gets a soft glow so it reads from
        // across the room; a settled pane doesn't.
        switch paneState {
        case .awaitingInput:
            stateIcon.layer.shadowColor = color.cgColor
            stateIcon.layer.shadowRadius = 3
            stateIcon.layer.shadowOpacity = 0.8
            stateIcon.layer.shadowOffset = .zero
        case .working:
            stateIcon.layer.shadowColor = color.cgColor
            stateIcon.layer.shadowRadius = 2.5
            stateIcon.layer.shadowOpacity = 0.6
            stateIcon.layer.shadowOffset = .zero
        case .idle:
            stateIcon.layer.shadowOpacity = 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
