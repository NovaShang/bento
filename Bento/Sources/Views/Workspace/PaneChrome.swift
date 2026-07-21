import UIKit
import BentoTerminalCore

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

/// Minimal title bar sitting atop a pane. Just a state dot + title — the
/// zoom + pane-menu actions live in the nav-bar ⋯ menu. Two looks:
///   • Tiled (multi-pane): a state-tinted band, brightening when active
///     (mirrors the macOS host's chrome).
///   • Single / focus: blends into the pane background (no contrast band),
///     so a fullscreen pane reads as one continuous surface.
///
/// Layout: [● state-dot] [title……………………………………………]
final class PaneTitleBar: UIView {
    let titleLabel = UILabel()
    private let stateDot = UIView()

    /// Drives dot color, the title-bar band color, and (when active) text emphasis.
    var paneState: PaneState = .idle {
        didSet { updateStateVisuals(); updateChrome() }
    }

    /// Active state drives the band chrome (tiled) / text emphasis (blend).
    var isActivePane: Bool = false {
        didSet { updateChrome() }
    }

    /// Tiled mode → macOS-style band chrome; otherwise blend into the
    /// pane background (`surfaceColor`).
    var isTiled: Bool = false {
        didSet { if oldValue != isTiled { updateChrome() } }
    }

    /// Pane background, used only in blend (non-tiled) mode so a fullscreen
    /// pane's title bar flows into the content. Ignored in tiled mode.
    var surfaceColor: UIColor = STTheme.term.bg {
        didSet { if !isTiled { backgroundColor = surfaceColor } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // In tiled mode the strip is short; clip so the centered dot never
        // spills onto the content below.
        clipsToBounds = true

        stateDot.layer.cornerRadius = 4
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateDot)

        titleLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = "agent"
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            stateDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stateDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateDot.widthAnchor.constraint(equalToConstant: 8),
            stateDot.heightAnchor.constraint(equalToConstant: 8),

            titleLabel.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])

        updateChrome()
    }

    /// Tiled: band + text track the pane state (blue / amber, neutral for
    /// idle), brightening when active — mirrors the macOS host. Blend (focus
    /// / single pane): the title bar flows into the pane background, text
    /// brightens only when active.
    private func updateChrome() {
        if isTiled {
            let accent = paneState.chromeAccentUIColor
            backgroundColor = STTheme.titleBand(accent: accent, active: isActivePane)
            titleLabel.textColor = STTheme.titleInk(accent: accent, active: isActivePane)
        } else {
            backgroundColor = surfaceColor
            titleLabel.textColor = isActivePane ? .label : .secondaryLabel
        }
    }

    /// Re-derive the band/ink for the current appearance (the band colors are
    /// resolved at compute time, not trait-reactive UIColors).
    func recolor() { updateChrome() }

    private func updateStateVisuals() {
        let dotColor = STTheme.dotColor(for: paneState)
        stateDot.backgroundColor = dotColor

        switch paneState {
        case .awaitingInput:
            stateDot.layer.shadowColor = dotColor.cgColor
            stateDot.layer.shadowRadius = 3
            stateDot.layer.shadowOpacity = 0.8
            stateDot.layer.shadowOffset = .zero
        case .working:
            stateDot.layer.shadowColor = dotColor.cgColor
            stateDot.layer.shadowRadius = 2.5
            stateDot.layer.shadowOpacity = 0.6
            stateDot.layer.shadowOffset = .zero
        case .idle:
            stateDot.layer.shadowOpacity = 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
