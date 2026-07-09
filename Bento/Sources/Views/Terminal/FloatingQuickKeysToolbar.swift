import UIKit
import BentoTerminalCore

/// Floating control strip for the active pane. Carries the agent-prompt nav
/// keys (↑ ↓ ↵ Esc Tab) and — for tmux panes — the pane actions (zoom + menu) that
/// used to live in the title bar. In tiled mode the title bar is only one
/// character cell tall, too short to host touch targets, so these moved here.
///
/// Rendered as a Liquid Glass capsule (`UIGlassEffect`, iOS 26+); older systems
/// fall back to an opaque Bento card. Docked **just below the active pane**,
/// right-aligned. The host reserves a fixed bottom band (`reservedBand`) so for
/// the bottom-most / full-screen pane the toolbar lands in that terminal-free
/// strip and never overlaps content; for a non-bottom tiled pane it sits over
/// the neighbour below (by design — the keys belong to the active pane). Hidden
/// while the keyboard is up, where the docked key bar takes over.
final class FloatingQuickKeysToolbar: UIView {

    // MARK: - Public API

    var onKeyTap: ((AccessoryKey) -> Void)?

    /// Tapped the zoom (maximize / restore) action.
    var onZoomTap: (() -> Void)?

    /// The pane-menu button — the host sets `.menu` to the active pane's menu
    /// (Split / Rename / Profile / Close). Shown only when `showsPaneActions`.
    let menuButton = UIButton(type: .system)

    /// Show the pane-action group (zoom + menu). False for a non-tmux single
    /// pane, which has nothing to split or zoom.
    var showsPaneActions: Bool = false {
        didSet { if oldValue != showsPaneActions { rebuild() } }
    }

    /// Whether the active pane is zoomed — drives the zoom icon (expand vs.
    /// restore).
    var isZoomed: Bool = false {
        didSet { if oldValue != isZoomed { updateZoomIcon() } }
    }

    // MARK: - Layout constants

    static let toolbarHeight: CGFloat = 38
    static let edgeGap: CGFloat = 10

    private static let buttonWidth: CGFloat = 48
    private static let buttonSpacing: CGFloat = 0

    // MARK: - Keys

    /// Minimal set tuned for agent prompt navigation: arrows step through
    /// option lists, Enter confirms, Esc dismisses, Tab completes / moves field.
    private static let keys: [Spec] = [
        .symbol(.up, system: "arrow.up"),
        .symbol(.down, system: "arrow.down"),
        .symbol(.enter, system: "return"),
        .text(.escape, label: "Esc"),
        .text(.tab, label: "Tab"),
        .symbol(.paste, system: "doc.on.clipboard"),
    ]

    private enum Spec {
        case symbol(AccessoryKey, system: String)
        case text(AccessoryKey, label: String)

        var key: AccessoryKey {
            switch self {
            case .symbol(let k, _), .text(let k, _): return k
            }
        }
    }

    // MARK: - Subviews

    /// Opaque fallback capsule for iOS < 26 (no Liquid Glass).
    private let card = UIView()
    /// Liquid Glass capsule on iOS 26+. When present, its `contentView` hosts the
    /// stack + separators; otherwise `card` does. See `contentHost`.
    private var glassView: UIVisualEffectView?
    /// The view that hosts the key stack + separators — glass `contentView` or card.
    private var contentHost: UIView { glassView?.contentView ?? card }
    private let stack = UIStackView()
    private let zoomButton = UIButton(type: .system)
    /// Hairlines between buttons, rebuilt with the stack.
    private var separators: [UIView] = []

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        backgroundColor = .clear

        // Background: Liquid Glass capsule on iOS 26+, opaque Bento card below.
        // `host` is where the key stack + separators live.
        let host = installBackground()

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = Self.buttonSpacing
        host.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        configureActionButtons()
        rebuild()
    }

    /// Install the capsule background and return the view that hosts the key
    /// stack. iOS 26 gets a translucent Liquid Glass capsule so the terminal
    /// content stays legible beneath the island; older systems keep the opaque
    /// Bento card with its 1px border.
    private func installBackground() -> UIView {
        let radius = Self.toolbarHeight / 2
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            let effectView = UIVisualEffectView(effect: glass)
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.layer.cornerRadius = radius
            effectView.clipsToBounds = true
            addSubview(effectView)
            pin(effectView)
            glassView = effectView
            return effectView.contentView
        } else {
            card.translatesAutoresizingMaskIntoConstraints = false
            card.backgroundColor = BentoBrand.surface
            card.layer.borderColor = BentoBrand.border.cgColor
            card.layer.borderWidth = 1
            card.layer.cornerRadius = radius
            card.clipsToBounds = true
            addSubview(card)
            pin(card)
            return card
        }
    }

    /// Pin a subview to fill the toolbar.
    private func pin(_ v: UIView) {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Configure the persistent zoom + menu buttons (reused across rebuilds).
    private func configureActionButtons() {
        zoomButton.configuration = symbolConfig("arrow.up.left.and.arrow.down.right")
        applyButtonStyle(zoomButton)
        zoomButton.addAction(UIAction { [weak self] _ in self?.onZoomTap?() }, for: .touchUpInside)

        menuButton.configuration = symbolConfig("ellipsis")
        applyButtonStyle(menuButton)
        menuButton.showsMenuAsPrimaryAction = true
    }

    /// Rebuild the stack from the nav keys plus, when enabled, the pane-action
    /// group. Cheap and infrequent (only when the mode flips).
    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        separators.removeAll()

        var items: [UIView] = Self.keys.map { makeKeyButton(spec: $0) }
        let actionStart = items.count
        if showsPaneActions {
            items.append(zoomButton)
            items.append(menuButton)
        }

        for (index, btn) in items.enumerated() {
            stack.addArrangedSubview(btn)
            guard index > 0 else { continue }
            // A slightly stronger divider marks the nav-keys ↔ pane-actions seam.
            addSeparator(before: btn, strong: index == actionStart)
        }
        invalidateIntrinsicContentSize()
    }

    private func addSeparator(before btn: UIView, strong: Bool) {
        let sep = UIView()
        sep.backgroundColor = UIColor(white: 1, alpha: strong ? 0.14 : 0.06)
        sep.translatesAutoresizingMaskIntoConstraints = false
        let host = contentHost
        host.addSubview(sep)
        separators.append(sep)
        let inset: CGFloat = strong ? 6 : 8
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 0.5),
            sep.topAnchor.constraint(equalTo: host.topAnchor, constant: inset),
            sep.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -inset),
            sep.leadingAnchor.constraint(equalTo: btn.leadingAnchor),
        ])
    }

    // MARK: - Button factory

    private func symbolConfig(_ name: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = BentoBrand.inkPrimary
        config.background.backgroundColor = .clear
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        let symConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        config.image = UIImage(systemName: name, withConfiguration: symConfig)
        config.preferredSymbolConfigurationForImage = symConfig
        return config
    }

    /// Shared highlight + minimum-width styling for every button.
    private func applyButtonStyle(_ btn: UIButton) {
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonWidth).isActive = true
        btn.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.background.backgroundColor = button.isHighlighted
                ? BentoBrand.surfaceHi
                : .clear
            button.configuration = updated
        }
    }

    private func makeKeyButton(spec: Spec) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = BentoBrand.inkPrimary
        config.background.backgroundColor = .clear
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)

        switch spec {
        case .symbol(_, let name):
            let symConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            config.image = UIImage(systemName: name, withConfiguration: symConfig)
            config.preferredSymbolConfigurationForImage = symConfig
        case .text(_, let label):
            config.title = label
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attrs = incoming
                attrs.font = .systemFont(ofSize: 14, weight: .semibold)
                return attrs
            }
        }

        let btn = UIButton(configuration: config)
        applyButtonStyle(btn)

        let key = spec.key
        btn.addAction(UIAction { [weak self] _ in
            self?.onKeyTap?(key)
        }, for: .touchUpInside)

        return btn
    }

    private func updateZoomIcon() {
        let name = isZoomed
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        zoomButton.configuration = symbolConfig(name)
    }

    // MARK: - Positioning

    /// Vertical gap between the active pane's bottom edge and the toolbar.
    static let paneGap: CGFloat = 6
    /// Gap kept below the toolbar, above the safe-area bottom.
    static let bottomGap: CGFloat = 6
    /// Inset of the toolbar's right edge from the pane's right edge.
    private static let rightInset: CGFloat = 8

    /// Total height the host must reserve at the bottom of the page so the
    /// toolbar never overlaps the active pane's content: the toolbar plus its
    /// top/bottom gaps.
    static var reservedBand: CGFloat { toolbarHeight + paneGap + bottomGap }

    /// Frame in `containerBounds`'s space: **right-aligned to the pane and docked
    /// just below its bottom edge**. The host reserves `reservedBand` at the page
    /// bottom, so for the bottom-most / full-screen pane this lands in that
    /// terminal-free band; for a non-bottom tiled pane it sits over the neighbour
    /// below (by design). Clamped to stay on screen.
    func computeFrame(paneFrame: CGRect, containerBounds: CGRect) -> CGRect {
        let intrinsicW = max(intrinsicContentSize.width, layoutFittingSize().width)
        let size = CGSize(width: intrinsicW, height: Self.toolbarHeight)
        let edge = Self.edgeGap

        // Right-aligned to the pane, clamped on screen.
        let desiredX = paneFrame.maxX - size.width - Self.rightInset
        let minX = containerBounds.minX + edge
        let maxX = containerBounds.maxX - size.width - edge
        let x = max(minX, min(maxX, desiredX))

        // Docked just below the pane's bottom edge; never past the usable bottom.
        let desiredY = paneFrame.maxY + Self.paneGap
        let y = min(desiredY, containerBounds.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Update the frame, animated on a 200ms ease-out curve.
    func updatePosition(paneFrame: CGRect, containerBounds: CGRect, animated: Bool) {
        let frame = computeFrame(paneFrame: paneFrame, containerBounds: containerBounds)
        let apply = { self.frame = frame }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut, animations: apply)
        } else {
            apply()
        }
    }

    // MARK: - Sizing

    override var intrinsicContentSize: CGSize {
        let fitted = layoutFittingSize()
        return CGSize(width: fitted.width, height: Self.toolbarHeight)
    }

    private func layoutFittingSize() -> CGSize {
        stack.layoutIfNeeded()
        let buttonsW = stack.arrangedSubviews.reduce(CGFloat(0)) { acc, view in
            acc + max(view.intrinsicContentSize.width,
                      view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width,
                      Self.buttonWidth)
        }
        let total = buttonsW + CGFloat(max(0, stack.arrangedSubviews.count - 1)) * Self.buttonSpacing
        return CGSize(width: total, height: Self.toolbarHeight)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Refresh CGColor on appearance changes — UIColor extensions don't
        // auto-resolve when written into layer properties. Only the opaque
        // fallback card has a border; the glass capsule adapts on its own.
        if glassView == nil {
            card.layer.borderColor = BentoBrand.border.cgColor
        }
    }
}
