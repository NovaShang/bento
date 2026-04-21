import UIKit

/// iOS glass pill showing quick keys for an awaiting pane.
/// Floats at top-right of the pane body, with pulsing amber dot + profile keys.
final class FloatingQuickKeysView: UIView {

    var onKeyTap: ((QuickKey) -> Void)?

    private let dotView = UIView()
    private let stackView = UIStackView()
    private var currentKeys: [QuickKey] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupView() {
        // Glass background
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 16
        blur.clipsToBounds = true
        addSubview(blur)

        // Shadow
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 9
        layer.shadowOffset = CGSize(width: 0, height: 6)

        // Amber pulse dot
        dotView.backgroundColor = STTheme.dotAwaiting
        dotView.layer.cornerRadius = 3
        dotView.layer.shadowColor = STTheme.dotAwaiting.cgColor
        dotView.layer.shadowRadius = 3
        dotView.layer.shadowOpacity = 0.8
        dotView.layer.shadowOffset = .zero
        dotView.translatesAutoresizingMaskIntoConstraints = false

        // Separator
        let sep = UIView()
        sep.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        sep.translatesAutoresizingMaskIntoConstraints = false

        // Button stack
        stackView.axis = .horizontal
        stackView.spacing = 0
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dotView)
        addSubview(sep)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),

            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            sep.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 8),
            sep.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            sep.widthAnchor.constraint(equalToConstant: 0.5),

            stackView.leadingAnchor.constraint(equalTo: sep.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),

            heightAnchor.constraint(equalToConstant: 32),
        ])

        startPulse()
    }

    func configure(with quickKeys: [QuickKey]) {
        guard quickKeys != currentKeys else { return }
        currentKeys = quickKeys

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (i, key) in quickKeys.enumerated() {
            let btn = UIButton(type: .system)
            btn.setTitle(key.label, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            btn.setTitleColor(.white, for: .normal)
            btn.tag = i

            let minW: CGFloat = key.label.count > 1 ? 38 : 32
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: minW).isActive = true

            // Inter-key separator
            if i > 0 {
                let keySep = UIView()
                keySep.backgroundColor = UIColor.white.withAlphaComponent(0.12)
                keySep.translatesAutoresizingMaskIntoConstraints = false
                stackView.addArrangedSubview(keySep)
                keySep.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
            }

            btn.addAction(UIAction { [weak self] _ in
                guard let self, i < self.currentKeys.count else { return }
                self.onKeyTap?(self.currentKeys[i])
            }, for: .touchUpInside)

            stackView.addArrangedSubview(btn)
        }
    }

    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotView.layer.add(pulse, forKey: "pulse")
    }

    func showAnimated() {
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: -4).scaledBy(x: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            self.alpha = 1
            self.transform = .identity
        }
    }
}

// Allow QuickKey equality check for diffing
extension QuickKey: Equatable {
    static func == (lhs: QuickKey, rhs: QuickKey) -> Bool {
        lhs.id == rhs.id && lhs.label == rhs.label
    }
}
