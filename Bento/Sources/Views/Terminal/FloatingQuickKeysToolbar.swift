import UIKit
import BentoTerminalCore

/// Floating quick-key strip for responding to interactive agent prompts.
/// Only carries the keys that matter in that workflow: ↑ ↓ ↵ Esc.
///
/// Visually a Bento card per `docs/design.md` §5 — `bentoSurface` fill, 1px
/// `bentoBorder` stroke, no shadow, no blur. Sits flush against the active
/// pane's bottom-left, auto-repositions to stay on screen and avoid occluding
/// the pane.
final class FloatingQuickKeysToolbar: UIView {

    // MARK: - Public API

    var onKeyTap: ((AccessoryKey) -> Void)?

    // MARK: - Layout constants

    static let toolbarHeight: CGFloat = 38
    static let edgeGap: CGFloat = 10

    private static let buttonWidth: CGFloat = 48
    private static let buttonSpacing: CGFloat = 0

    // MARK: - Keys

    /// Minimal set tuned for agent prompt navigation: arrows step through
    /// option lists, Enter confirms, Esc dismisses.
    private static let keys: [Spec] = [
        .symbol(.up, system: "arrow.up"),
        .symbol(.down, system: "arrow.down"),
        .symbol(.enter, system: "return"),
        .text(.escape, label: "Esc"),
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
    private let divider = UIColor(white: 1, alpha: 0.06)  // hairline between buttons

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

        for (index, spec) in Self.keys.enumerated() {
            let btn = makeButton(spec: spec)
            stack.addArrangedSubview(btn)
            // Hairline between buttons — same convention as iOS grouped
            // toolbar segmented buttons.
            if index > 0 {
                let sep = UIView()
                sep.backgroundColor = divider
                sep.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.widthAnchor.constraint(equalToConstant: 0.5),
                    sep.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                    sep.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
                    sep.leadingAnchor.constraint(equalTo: btn.leadingAnchor),
                ])
            }
        }
    }

    private func makeButton(spec: Spec) -> UIButton {
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
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonWidth).isActive = true

        btn.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.background.backgroundColor = button.isHighlighted
                ? BentoBrand.surfaceHi
                : .clear
            button.configuration = updated
        }

        let key = spec.key
        btn.addAction(UIAction { [weak self] _ in
            self?.onKeyTap?(key)
        }, for: .touchUpInside)

        return btn
    }

    // MARK: - Positioning

    /// Compute the toolbar's frame in `containerBounds`'s coordinate space,
    /// given the active pane's frame in the same space.
    ///
    /// Algorithm:
    ///   1. Below pane, top-left aligned to pane bottom-left.
    ///   2. Shift left if it would extend past container right.
    ///   3. Flip above pane if no vertical room below.
    ///   4. Last resort: bottom-right corner, semi-transparent.
    func computeFrame(paneFrame: CGRect, containerBounds: CGRect) -> (frame: CGRect, isLastResort: Bool) {
        let intrinsicW = max(intrinsicContentSize.width, layoutFittingSize().width)
        let size = CGSize(width: intrinsicW, height: Self.toolbarHeight)
        let gap = Self.edgeGap

        func clampX(_ x: CGFloat) -> CGFloat {
            let minX = containerBounds.minX + gap
            let maxX = containerBounds.maxX - size.width - gap
            return max(minX, min(maxX, x))
        }

        let belowY = paneFrame.maxY + gap
        if belowY + size.height <= containerBounds.maxY - gap {
            return (CGRect(origin: CGPoint(x: clampX(paneFrame.minX), y: belowY), size: size), false)
        }

        let aboveY = paneFrame.minY - size.height - gap
        if aboveY >= containerBounds.minY + gap {
            return (CGRect(origin: CGPoint(x: clampX(paneFrame.minX), y: aboveY), size: size), false)
        }

        let x = containerBounds.maxX - size.width - gap
        let y = containerBounds.maxY - size.height - gap
        return (CGRect(origin: CGPoint(x: x, y: y), size: size), true)
    }

    /// Update frame + dimming, animated on a 200ms ease-out curve.
    func updatePosition(paneFrame: CGRect, containerBounds: CGRect, animated: Bool) {
        let (frame, lastResort) = computeFrame(paneFrame: paneFrame, containerBounds: containerBounds)
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
