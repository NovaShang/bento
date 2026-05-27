import UIKit
import SwiftTerm

/// Convert a 24-bit RGB hex to a SwiftTerm.Color (16-bit per channel).
/// Replicating the byte fills the high byte so 0xFF maps to 0xFFFF.
func swiftTermColor(fromHex hex: UInt32) -> SwiftTerm.Color {
    let r = UInt16((hex >> 16) & 0xFF) * 257
    let g = UInt16((hex >> 8) & 0xFF) * 257
    let b = UInt16(hex & 0xFF) * 257
    return SwiftTerm.Color(red: r, green: g, blue: b)
}

/// Standard xterm 16-color palette. Used to reset back to defaults when the
/// user switches from a custom theme to "System".
nonisolated(unsafe) let SwiftTermDefaultPalette: [SwiftTerm.Color] = [
    swiftTermColor(fromHex: 0x000000), swiftTermColor(fromHex: 0xCD0000),
    swiftTermColor(fromHex: 0x00CD00), swiftTermColor(fromHex: 0xCDCD00),
    swiftTermColor(fromHex: 0x0000EE), swiftTermColor(fromHex: 0xCD00CD),
    swiftTermColor(fromHex: 0x00CDCD), swiftTermColor(fromHex: 0xE5E5E5),
    swiftTermColor(fromHex: 0x7F7F7F), swiftTermColor(fromHex: 0xFF0000),
    swiftTermColor(fromHex: 0x00FF00), swiftTermColor(fromHex: 0xFFFF00),
    swiftTermColor(fromHex: 0x5C5CFF), swiftTermColor(fromHex: 0xFF00FF),
    swiftTermColor(fromHex: 0x00FFFF), swiftTermColor(fromHex: 0xFFFFFF),
]

/// Hosts a single SwiftTerm TerminalView for one pane, with a title bar.
/// No gesture handling — all gestures are managed by GestureCoordinator.
final class TerminalContainerVC: UIViewController {
    private(set) var terminalView: TerminalView!
    private let accessoryView = KeyboardAccessoryView()
    let titleBar = PaneTitleBar()

    var paneVM: PaneViewModel?
    var terminalVM: TerminalViewModel?

    private static let titleBarHeight: CGFloat = 38

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term.bg
        setupTitleBar()
        setupTerminalView()
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
    @objc private func fontDidChange() {
        terminalView.font = STTheme.terminalFont
    }

    /// Apply the user-selected color theme to the TerminalView.
    private func applyTheme() {
        let theme = ThemeStore.shared.current

        // The "system" theme uses STTheme dynamic colors so it follows the
        // OS appearance. All other themes ship a static palette.
        if theme.id == TerminalColorTheme.systemID {
            terminalView.nativeBackgroundColor = STTheme.term.bg
            terminalView.nativeForegroundColor = STTheme.term.fg
            view.backgroundColor = STTheme.term.bg
            terminalView.installColors(SwiftTermDefaultPalette)
        } else {
            terminalView.nativeBackgroundColor = theme.bgColor
            terminalView.nativeForegroundColor = theme.fgColor
            view.backgroundColor = theme.bgColor
            let palette = theme.ansi.map { swiftTermColor(fromHex: $0) }
            terminalView.installColors(palette)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let tbh = Self.titleBarHeight
        terminalView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: max(0, view.bounds.height - tbh))
        titleBar.frame = CGRect(x: 0, y: view.bounds.height - tbh, width: view.bounds.width, height: tbh)
    }

    // MARK: - Setup

    private func setupTitleBar() {
        let tbh = Self.titleBarHeight
        titleBar.frame = CGRect(x: 0, y: view.bounds.height - tbh, width: view.bounds.width, height: tbh)
        titleBar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        titleBar.quickKeys = Self.defaultQuickKeys
        titleBar.onQuickKeyTap = { [weak self] key in
            var str = key.keys
            if key.isEnter { str += "\r" }
            self?.sendString(str)
        }
        view.addSubview(titleBar)
    }

    private func setupTerminalView() {
        let tbh = Self.titleBarHeight
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: max(0, view.bounds.height - tbh)))
        terminalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminalView.terminalDelegate = self
        terminalView.nativeBackgroundColor = STTheme.term.bg
        terminalView.nativeForegroundColor = STTheme.term.fg

        terminalView.font = STTheme.terminalFont

        terminalView.inputAccessoryView = accessoryView
        accessoryView.onKeyTap = { [weak self] key in
            self?.handleAccessoryKey(key)
        }

        view.addSubview(terminalView)
        // Gesture setup is done by GestureCoordinator.attachPaneGestures()
    }

    // MARK: - Title & State

    func updateTitle(_ title: String) {
        titleBar.titleLabel.text = title
    }

    func updatePaneState(_ state: PaneState, active: Bool) {
        titleBar.paneState = state
        titleBar.isActivePane = active

        // For the System theme we tint the bg per state (subtle warm/green
        // wash). For user-selected themes we leave the terminal bg untouched
        // so the chosen palette is preserved as-is — the state dot in the
        // title bar still communicates the state.
        let isSystem = ThemeStore.shared.current.id == TerminalColorTheme.systemID
        let bgColor = isSystem ? STTheme.paneBackground(for: state)
                               : ThemeStore.shared.current.bgColor
        UIView.animate(withDuration: 0.26) {
            self.view.backgroundColor = bgColor
            self.terminalView.nativeBackgroundColor = bgColor
        }
    }

    // MARK: - Quick Keys

    /// Default quick keys shown in the title bar when this pane is active.
    /// Surfaces basic navigation that's awkward on the on-screen keyboard.
    fileprivate static let defaultQuickKeys: [QuickKey] = [
        QuickKey(id: "up", label: "↑", keys: "\u{1b}[A", isEnter: false),
        QuickKey(id: "down", label: "↓", keys: "\u{1b}[B", isEnter: false),
        QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
        QuickKey(id: "esc", label: "Esc", keys: "\u{1b}", isEnter: false),
    ]

    // MARK: - Binding

    func bindToPaneVM(_ vm: PaneViewModel) {
        self.paneVM = vm
        vm.onDataReceived = { [weak self] data in
            DispatchQueue.main.async {
                let bytes = ArraySlice<UInt8>(data)
                self?.terminalView.feed(byteArray: bytes)
            }
        }
        updateTitle(vm.pane.currentCommand ?? "shell")
    }

    func bindToTerminalVM(_ vm: TerminalViewModel) {
        self.terminalVM = vm
        vm.onRawDataReceived = { [weak self] data in
            DispatchQueue.main.async {
                let bytes = ArraySlice<UInt8>(data)
                self?.terminalView.feed(byteArray: bytes)
            }
        }
    }

    var terminalSize: (cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminal.cols, terminal.rows)
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

    private func handleAccessoryKey(_ key: AccessoryKey) {
        switch key {
        case .escape: sendString("\u{1B}")
        case .tab: sendString("\t")
        case .ctrl: accessoryView.toggleCtrl()
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
}

// MARK: - TerminalViewDelegate

extension TerminalContainerVC: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
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

    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) { updateTitle(title) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if paneVM == nil { terminalVM?.resizeTerminal(cols: newCols, rows: newRows) }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

// MARK: - Pane Title Bar

/// Bottom-anchored pane chrome.
///
/// Voice lives on the far right and is always visible — it's the primary
/// interaction affordance for this app, so it stays put regardless of state.
/// Layout swaps based on `isActivePane`:
///  - Inactive: [● dot] [title……………] [⋯ menu] [🎤 voice]
///  - Active:   [● dot] [↑][↓][↵][Esc]………… [⋯ menu] [🎤 voice]
final class PaneTitleBar: UIView {
    let titleLabel = UILabel()
    let voiceButton = UIButton(type: .system)
    let menuButton = UIButton(type: .system)
    private let stateDot = UIView()
    private let quickKeysStack = UIStackView()

    /// Action when a quick key button is tapped while the pane is active.
    var onQuickKeyTap: ((QuickKey) -> Void)?

    /// Current pane state — drives dot color and title bar tint
    var paneState: PaneState = .idle {
        didSet { updateStateVisuals() }
    }

    /// Whether this is the active (selected) pane. Toggles between
    /// title-mode (inactive) and quick-keys-mode (active).
    var isActivePane: Bool = false {
        didSet { updateActiveLayout() }
    }

    /// Quick keys shown in the title bar when the pane is active.
    var quickKeys: [QuickKey] = [] {
        didSet { rebuildQuickKeys() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .secondarySystemBackground

        // Top hairline so the bar reads as a separate chrome strip below the terminal
        let hairline = UIView()
        hairline.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        // State dot
        stateDot.layer.cornerRadius = 4
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateDot)

        // Title
        titleLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = "shell"
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Quick keys stack — appears in place of the title when active
        quickKeysStack.axis = .horizontal
        quickKeysStack.spacing = 6
        quickKeysStack.alignment = .center
        quickKeysStack.distribution = .fillEqually
        quickKeysStack.translatesAutoresizingMaskIntoConstraints = false
        quickKeysStack.isHidden = true
        addSubview(quickKeysStack)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)

        // Voice button — quick affordance to focus this pane for voice input
        voiceButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: iconConfig), for: .normal)
        voiceButton.tintColor = .secondaryLabel
        voiceButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(voiceButton)

        // Menu button — ellipsis icon
        menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: iconConfig), for: .normal)
        menuButton.tintColor = .secondaryLabel
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuButton)

        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            stateDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stateDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateDot.widthAnchor.constraint(equalToConstant: 8),
            stateDot.heightAnchor.constraint(equalToConstant: 8),

            voiceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            voiceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            voiceButton.widthAnchor.constraint(equalToConstant: 32),
            voiceButton.heightAnchor.constraint(equalToConstant: 30),

            menuButton.trailingAnchor.constraint(equalTo: voiceButton.leadingAnchor, constant: -2),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 32),
            menuButton.heightAnchor.constraint(equalToConstant: 30),

            titleLabel.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -6),

            quickKeysStack.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: 10),
            quickKeysStack.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -6),
            quickKeysStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            quickKeysStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        updateStateVisuals()
        updateActiveLayout()
    }

    private func updateActiveLayout() {
        titleLabel.isHidden = isActivePane
        quickKeysStack.isHidden = !isActivePane
        updateStateVisuals()
    }

    private func rebuildQuickKeys() {
        quickKeysStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in quickKeys {
            let btn = makeQuickKeyButton(for: key)
            quickKeysStack.addArrangedSubview(btn)
        }
    }

    private func makeQuickKeyButton(for key: QuickKey) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = key.label
        config.cornerStyle = .medium
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attrs = incoming
            attrs.font = .systemFont(ofSize: 13, weight: .medium)
            return attrs
        }
        let btn = UIButton(configuration: config)
        btn.addAction(UIAction { [weak self] _ in
            self?.onQuickKeyTap?(key)
        }, for: .touchUpInside)
        return btn
    }

    private func updateStateVisuals() {
        let dotColor = STTheme.dotColor(for: paneState)
        stateDot.backgroundColor = dotColor

        // Glow for awaiting/working dots
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

        // Title bar tint based on active state
        if isActivePane {
            backgroundColor = UIColor.tintColor.withAlphaComponent(0.12)
            titleLabel.textColor = .label
        } else {
            backgroundColor = .secondarySystemBackground
            titleLabel.textColor = .secondaryLabel
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
