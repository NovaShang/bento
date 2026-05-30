import UIKit
import BentoTerminalCore
import SwiftTmux

/// Hosts a single libghostty terminal surface for one pane.
/// Owns its narrow title bar (above the terminal) and the gesture wiring for
/// voice press, pane selection tap, and double-tap-to-keyboard.
///
/// The terminal engine is reached only through `BentoTerminalCore.TerminalSurface`
/// — this VC is the single adapter between Bento's pane/session orchestration and
/// the concrete renderer.
final class TerminalContainerVC: UIViewController {
    private(set) var surface: GhosttyTerminalSurface!
    private let accessoryView = KeyboardAccessoryView()
    let titleBar = PaneTitleBar()

    var paneVM: PaneViewModel?
    var terminalVM: TerminalViewModel?

    /// Voice gesture pipeline. Parent VC injects the controller; we just
    /// forward `handleLongPress` states.
    weak var voiceController: VoiceInputController?

    // MARK: - Callbacks (set by parent)

    /// User tapped the pane — request that this pane become active. Parent VC
    /// translates this into `viewModel.selectPane(...)`.
    var onSelectPaneTapped: (() -> Void)?

    /// User asked to split this pane (horizontally or vertically).
    var onSplitRequested: ((_ horizontal: Bool) -> Void)?

    /// User asked to close this pane.
    var onCloseRequested: (() -> Void)?

    /// User asked to toggle zoom (maximize / restore) on this pane.
    var onToggleZoom: (() -> Void)?

    /// The surface reported its current cols × rows after layout. Parent VC uses
    /// this to drive tmux client resize (refresh-client -C). Authoritative —
    /// any homemade cell-size math will drift from the engine's internal
    /// measurement and cause TUI wrap mismatches.
    var onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)?

    private static let titleBarHeight: CGFloat = 32

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term.bg
        setupSurface()
        setupTitleBar()
        attachGestures()
        applyTheme()
        observeAppearanceChanges()
    }

    private func observeAppearanceChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .terminalThemeChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontDidChange),
            name: .terminalFontChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() { applyTheme() }
    @objc private func fontDidChange() { applyTheme() }

    /// Build the engine-agnostic theme from the current ThemeStore selection.
    private func currentTerminalTheme() -> TerminalTheme {
        let t = ThemeStore.shared.current
        let fontSize = Double(STTheme.terminalFontSize)
        return TerminalTheme(
            background: t.bg,
            foreground: t.fg,
            ansi: t.ansi,
            fontSize: fontSize
        )
    }

    /// Apply the user-selected color theme.
    private func applyTheme() {
        let theme = ThemeStore.shared.current
        surface.applyTheme(currentTerminalTheme())

        let bgColor: UIColor
        if theme.id == TerminalColorTheme.systemID {
            bgColor = STTheme.term.bg
        } else {
            bgColor = theme.bgColor
        }
        view.backgroundColor = bgColor
        surface.backgroundColor = bgColor
        // Title bar background tracks terminal background so the two surfaces
        // visually flow into each other — no separator line, no contrast band.
        titleBar.surfaceColor = bgColor
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let tbh = Self.titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        surface.frame = CGRect(x: 0, y: tbh, width: view.bounds.width,
                               height: max(0, view.bounds.height - tbh))
    }

    // MARK: - Setup

    private func setupTitleBar() {
        let tbh = Self.titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        titleBar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        titleBar.surfaceColor = view.backgroundColor ?? STTheme.term.bg

        // Maximize toggles tmux zoom on this pane (via parent callback).
        titleBar.onMaximizeTapped = { [weak self] in
            self?.onToggleZoom?()
        }

        // Defer menu construction so each open reflects current state.
        titleBar.menuButton.showsMenuAsPrimaryAction = true
        titleBar.menuButton.menu = makePaneMenu()

        view.addSubview(titleBar)
    }

    private func setupSurface() {
        let tbh = Self.titleBarHeight
        surface = GhosttyTerminalSurface(theme: currentTerminalTheme())
        surface.frame = CGRect(x: 0, y: tbh, width: view.bounds.width,
                               height: max(0, view.bounds.height - tbh))
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Bytes the engine wants to send to the host (keystrokes, query
        // responses). Apply the soft-Ctrl modifier here, mirroring the old
        // SwiftTerm `send` path.
        surface.onInput = { [weak self] data in
            self?.handleSurfaceInput(data)
        }
        surface.onSizeChanged = { [weak self] size in
            guard let self else { return }
            if self.paneVM == nil {
                self.terminalVM?.resizeTerminal(cols: size.columns, rows: size.rows)
            }
            self.onSizeChanged?(size.columns, size.rows)
        }
        surface.onTitleChanged = { [weak self] title in
            self?.updateTitle(title)
        }

        surface.inputAccessoryView = accessoryView
        accessoryView.onKeyTap = { [weak self] key in
            self?.handleAccessoryKey(key)
        }

        view.addSubview(surface)
    }

    /// Apply the soft-Ctrl modifier and route to the transport. The engine has
    /// already encoded the keystroke; we only fold in Bento's on-screen Ctrl key.
    private func handleSurfaceInput(_ data: Data) {
        var bytes = [UInt8](data)
        if accessoryView.isCtrlActive, bytes.count == 1 {
            let byte = bytes[0]
            if byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") {
                bytes = [byte - UInt8(ascii: "a") + 1]
            } else if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") {
                bytes = [byte - UInt8(ascii: "A") + 1]
            }
            accessoryView.deactivateCtrl()
        }
        sendData(Data(bytes))
    }

    // MARK: - Gestures

    /// Inline gesture wiring. The libghostty surface has no built-in
    /// tap-to-keyboard or long-press selection, so unlike the SwiftTerm era we
    /// don't have to suppress any pre-existing recognizers — we just add ours.
    ///   - Voice press commits at 180ms (see VoicePressGesture).
    ///   - Single tap selects the pane.
    ///   - Double tap toggles the keyboard.
    private func attachGestures() {
        let voicePress = VoicePressGesture(target: self, action: #selector(handleVoicePress(_:)))
        voicePress.delegate = self
        surface.addGestureRecognizer(voicePress)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.cancelsTouchesInView = false
        singleTap.delaysTouchesBegan = false
        singleTap.delaysTouchesEnded = false
        singleTap.delegate = self
        surface.addGestureRecognizer(singleTap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        surface.addGestureRecognizer(doubleTap)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        onSelectPaneTapped?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if surface.isFirstResponder {
            // Already typing — second double-tap should dismiss.
            view.endEditing(true)
        } else {
            _ = surface.becomeFirstResponder()
        }
    }

    @objc private func handleVoicePress(_ gesture: VoicePressGesture) {
        guard let controller = voiceController, let view = gesture.view else { return }
        // Selecting on press makes voice transcripts land on the right pane
        // even if the user starts holding on a non-active pane.
        if gesture.state == .began { onSelectPaneTapped?() }
        let local = gesture.currentLocation()
        // VoiceInputController positions its overlay in screen (window) coords,
        // so convert before forwarding.
        let screen = view.convert(local, to: nil)
        controller.handleLongPress(state: gesture.state, location: screen)
    }

    // MARK: - Title & State

    func updateTitle(_ title: String) {
        titleBar.titleLabel.text = title
    }

    func updatePaneState(_ state: PaneState, active: Bool) {
        titleBar.paneState = state
        titleBar.isActivePane = active

        let isSystem = ThemeStore.shared.current.id == TerminalColorTheme.systemID
        let bgColor = isSystem ? STTheme.paneBackground(for: state)
                               : ThemeStore.shared.current.bgColor
        UIView.animate(withDuration: 0.26) {
            self.view.backgroundColor = bgColor
            self.surface.backgroundColor = bgColor
            self.titleBar.surfaceColor = bgColor
        }
    }

    // MARK: - Binding

    func bindToPaneVM(_ vm: PaneViewModel) {
        self.paneVM = vm
        vm.onDataReceived = { [weak self] data in
            DispatchQueue.main.async {
                self?.surface.feed(data)
            }
        }
        updateTitle(vm.pane.currentCommand ?? "shell")
    }

    func bindToTerminalVM(_ vm: TerminalViewModel) {
        self.terminalVM = vm
        vm.onRawDataReceived = { [weak self] data in
            DispatchQueue.main.async {
                self?.surface.feed(data)
            }
        }
    }

    var terminalSize: (cols: Int, rows: Int) {
        guard let size = surface.currentSize else { return (0, 0) }
        return (size.columns, size.rows)
    }

    // MARK: - Pane Menu

    private func makePaneMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Split Horizontal",
                     image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                self?.onSplitRequested?(true)
            },
            UIAction(title: "Split Vertical",
                     image: UIImage(systemName: "rectangle.split.1x2")) { [weak self] _ in
                self?.onSplitRequested?(false)
            },
            UIAction(title: "Close Pane",
                     image: UIImage(systemName: "xmark"),
                     attributes: .destructive) { [weak self] _ in
                self?.onCloseRequested?()
            },
        ])
    }

    // MARK: - Input

    private func sendData(_ data: Data) {
        if let paneVM { paneVM.sendInput(data) }
        else { terminalVM?.sendData(data) }
    }

    private func sendString(_ string: String) {
        if let paneVM { paneVM.sendString(string) }
        else { terminalVM?.sendString(string) }
    }

    /// Route both the inputAccessoryView and the floating quick-keys toolbar
    /// through the same key handler. The Ctrl state is owned by the accessory
    /// view; the floating toolbar mirrors that state visually via its own
    /// `isCtrlActive` property.
    func handleAccessoryKey(_ key: AccessoryKey) {
        switch key {
        case .escape: sendString("\u{1B}")
        case .tab: sendString("\t")
        case .ctrl: accessoryView.toggleCtrl()
        case .enter: sendString("\r")
        case .up: sendString("\u{1B}[A")
        case .down: sendString("\u{1B}[B")
        case .right: sendString("\u{1B}[C")
        case .left: sendString("\u{1B}[D")
        case .pipe: sendString("|")
        case .slash: sendString("/")
        case .tilde: sendString("~")
        case .dash: sendString("-")
        }
    }

    /// Whether the Ctrl modifier on the soft keyboard accessory is armed.
    var isCtrlActive: Bool { accessoryView.isCtrlActive }
}

// MARK: - UIGestureRecognizerDelegate

extension TerminalContainerVC: @preconcurrency UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Our tap / voice-press recognizers are passive and should coexist with
        // any recognizers the surface may add (scroll, etc.).
        return true
    }
}

// MARK: - Pane Title Bar

/// Minimal title bar sitting flush above the terminal.
/// Background matches the terminal's background — no border, no contrast band,
/// title and content visually flow as one surface.
///
/// Layout: [● state-dot] [title…………………………] [⋯ menu] [⛶ maximize]
final class PaneTitleBar: UIView {
    let titleLabel = UILabel()
    let menuButton = UIButton(type: .system)
    let maximizeButton = UIButton(type: .system)
    private let stateDot = UIView()

    /// Tap handler for the maximize button.
    var onMaximizeTapped: (() -> Void)?

    /// Drives dot color and (when active) text emphasis.
    var paneState: PaneState = .idle {
        didSet { updateStateVisuals() }
    }

    /// Active state determines whether the menu / maximize buttons are
    /// shown and how prominently the title is rendered.
    var isActivePane: Bool = false {
        didSet { updateActiveLayout() }
    }

    /// Title bar background color. Set by the host VC to match the terminal
    /// background — no separator, two surfaces blend into one.
    var surfaceColor: UIColor = STTheme.term.bg {
        didSet { backgroundColor = surfaceColor }
    }

    /// Whether the maximize button shows the "exit" (restore) icon.
    var isMaximized: Bool = false {
        didSet { updateMaximizeIcon() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = surfaceColor

        stateDot.layer.cornerRadius = 4
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateDot)

        titleLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = "shell"
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)

        maximizeButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                        withConfiguration: iconConfig), for: .normal)
        maximizeButton.tintColor = .secondaryLabel
        maximizeButton.translatesAutoresizingMaskIntoConstraints = false
        maximizeButton.addAction(UIAction { [weak self] _ in
            self?.onMaximizeTapped?()
        }, for: .touchUpInside)
        addSubview(maximizeButton)

        menuButton.setImage(UIImage(systemName: "ellipsis",
                                    withConfiguration: iconConfig), for: .normal)
        menuButton.tintColor = .secondaryLabel
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuButton)

        NSLayoutConstraint.activate([
            stateDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stateDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateDot.widthAnchor.constraint(equalToConstant: 8),
            stateDot.heightAnchor.constraint(equalToConstant: 8),

            maximizeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            maximizeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            maximizeButton.widthAnchor.constraint(equalToConstant: 32),
            maximizeButton.heightAnchor.constraint(equalToConstant: 28),

            menuButton.trailingAnchor.constraint(equalTo: maximizeButton.leadingAnchor, constant: -2),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 32),
            menuButton.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -6),
        ])

        updateStateVisuals()
        updateActiveLayout()
    }

    private func updateActiveLayout() {
        menuButton.isHidden = !isActivePane
        maximizeButton.isHidden = !isActivePane
        updateStateVisuals()
    }

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

        titleLabel.textColor = isActivePane ? .label : .secondaryLabel
        menuButton.tintColor = .secondaryLabel
        maximizeButton.tintColor = .secondaryLabel
    }

    private func updateMaximizeIcon() {
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let name = isMaximized
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        maximizeButton.setImage(UIImage(systemName: name, withConfiguration: iconConfig), for: .normal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
