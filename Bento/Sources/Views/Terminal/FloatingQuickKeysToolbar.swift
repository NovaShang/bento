import UIKit
import BentoTerminalCore

/// Floating control strip for the active pane. Carries the agent-prompt nav
/// keys (↑ ↓ ↵ Esc Tab) and — for tmux panes — the pane actions (zoom + menu) that
/// used to live in the title bar. In tiled mode the title bar is only one
/// character cell tall, too short to host touch targets, so these moved here.
///
/// Visually a Bento card per `docs/design.md` §5 — `bentoSurface` fill, 1px
/// `bentoBorder` stroke, no shadow, no blur. Sits flush against the active
/// pane's bottom-left, auto-repositions to stay on screen and avoid occluding
/// the pane.
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

    private let card = UIView()
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

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BentoBrand.surface
        card.layer.borderColor = BentoBrand.border.cgColor
        card.layer.borderWidth = 1
        card.layer.cornerRadius = Self.toolbarHeight / 2
        card.clipsToBounds = true
        addSubview(card)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = Self.buttonSpacing
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])

        configureActionButtons()
        rebuild()
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
        card.addSubview(sep)
        separators.append(sep)
        let inset: CGFloat = strong ? 6 : 8
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 0.5),
            sep.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            sep.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
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

    /// A few points of breathing room between the toolbar and the pane's content
    /// edge — small so the toolbar hugs the content. It may cover the title-bar
    /// chrome but never the content.
    private static let contentGap: CGFloat = 4
    /// Inset of the toolbar's right edge from the pane's right edge.
    private static let rightInset: CGFloat = 8

    /// Compute the toolbar's frame in `containerBounds`'s coordinate space,
    /// given the active pane's frame and its title-bar height (where content
    /// begins) in the same space. Right-aligned to the pane.
    ///
    /// Algorithm:
    ///   1. Above the content, covering the title bar — bottom a few px above the
    ///      content top. Preferred (anchors by the title bar).
    ///   2. Below the content — top a few px under the pane bottom — if there's
    ///      no room above (e.g. a top-row pane).
    ///   3. Last resort (pane fills the viewport, e.g. focus): pinned over the
    ///      title bar, clamped on-screen, semi-transparent; may cover a little
    ///      content where there is genuinely no room.
    func computeFrame(paneFrame: CGRect, titleBarHeight: CGFloat,
                      containerBounds: CGRect) -> (frame: CGRect, isLastResort: Bool) {
        let intrinsicW = max(intrinsicContentSize.width, layoutFittingSize().width)
        let size = CGSize(width: intrinsicW, height: Self.toolbarHeight)
        let edge = Self.edgeGap

        // Right edge flush to the pane's right edge (minus a small inset),
        // clamped to stay on screen.
        let desiredX = paneFrame.maxX - size.width - Self.rightInset
        let minX = containerBounds.minX + edge
        let maxX = containerBounds.maxX - size.width - edge
        let x = max(minX, min(maxX, desiredX))

        func framed(_ y: CGFloat) -> CGRect {
            CGRect(x: x, y: y, width: size.width, height: size.height)
        }

        let contentTop = paneFrame.minY + titleBarHeight

        // 1. Above the content, covering the title bar.
        let aboveY = contentTop - Self.contentGap - size.height
        if aboveY >= containerBounds.minY + edge {
            return (framed(aboveY), false)
        }

        // 2. Just below the content.
        let belowY = paneFrame.maxY + Self.contentGap
        if belowY + size.height <= containerBounds.maxY - edge {
            return (framed(belowY), false)
        }

        // 3. Last resort: clamp the above-position into the container.
        let y = max(containerBounds.minY + edge,
                    min(containerBounds.maxY - size.height - edge, aboveY))
        return (framed(y), true)
    }

    /// Update frame + dimming, animated on a 200ms ease-out curve.
    func updatePosition(paneFrame: CGRect, titleBarHeight: CGFloat,
                        containerBounds: CGRect, animated: Bool) {
        let (frame, lastResort) = computeFrame(paneFrame: paneFrame,
                                               titleBarHeight: titleBarHeight,
                                               containerBounds: containerBounds)
        let targetAlpha: CGFloat = lastResort ? 0.78 : 1.0
        let apply = {
            self.frame = frame
            self.alpha = targetAlpha
        }
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
        // auto-resolve when written into layer properties.
        card.layer.borderColor = BentoBrand.border.cgColor
    }
}
