import UIKit
import SwiftTerm

/// Hosts a single SwiftTerm TerminalView for one pane, with a title bar.
/// No gesture handling — all gestures are managed by GestureCoordinator.
final class TerminalContainerVC: UIViewController {
    private(set) var terminalView: TerminalView!
    private let accessoryView = KeyboardAccessoryView()
    let titleBar = PaneTitleBar()

    var paneVM: PaneViewModel?
    var terminalVM: TerminalViewModel?

    private static let titleBarHeight: CGFloat = 26

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term.bg
        setupTitleBar()
        setupTerminalView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let tbh = Self.titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        terminalView.frame = CGRect(x: 0, y: tbh, width: view.bounds.width, height: view.bounds.height - tbh)
    }

    // MARK: - Setup

    private func setupTitleBar() {
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: Self.titleBarHeight)
        titleBar.autoresizingMask = [.flexibleWidth]
        view.addSubview(titleBar)
    }

    private func setupTerminalView() {
        let tbh = Self.titleBarHeight
        terminalView = TerminalView(frame: CGRect(x: 0, y: tbh, width: view.bounds.width, height: view.bounds.height - tbh))
        terminalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminalView.terminalDelegate = self
        terminalView.nativeBackgroundColor = STTheme.term.bg
        terminalView.nativeForegroundColor = STTheme.term.fg

        terminalView.font = UIFont.monospacedSystemFont(ofSize: STTheme.terminalFontSize, weight: .regular)

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

        // Update terminal background tint based on state
        let bgColor = STTheme.paneBackground(for: state)
        UIView.animate(withDuration: 0.26) {
            self.view.backgroundColor = bgColor
            self.terminalView.nativeBackgroundColor = bgColor
        }
    }

    // MARK: - Quick Keys

    private static let defaultQuickKeys: [QuickKey] = [
        QuickKey(id: "up", label: "↑", keys: "\u{1b}[A", isEnter: false),
        QuickKey(id: "down", label: "↓", keys: "\u{1b}[B", isEnter: false),
        QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
        QuickKey(id: "esc", label: "Esc", keys: "\u{1b}", isEnter: false),
    ]

    private var quickKeysView: FloatingQuickKeysView?

    func showQuickKeys(_ show: Bool) {
        if show {
            if quickKeysView == nil {
                let qk = FloatingQuickKeysView()
                qk.onKeyTap = { [weak self] key in
                    var str = key.keys
                    if key.isEnter { str += "\r" }
                    self?.sendString(str)
                }
                qk.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(qk)
                NSLayoutConstraint.activate([
                    qk.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 6),
                    qk.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                ])
                qk.configure(with: Self.defaultQuickKeys)
                quickKeysView = qk
                qk.showAnimated()
            }
        } else {
            quickKeysView?.removeFromSuperview()
            quickKeysView = nil
        }
    }

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

final class PaneTitleBar: UIView {
    let titleLabel = UILabel()
    let focusButton = UIButton(type: .system)
    let menuButton = UIButton(type: .system)
    private let stateDot = UIView()

    /// Current pane state — drives dot color and title bar tint
    var paneState: PaneState = .idle {
        didSet { updateStateVisuals() }
    }

    /// Whether this is the active (selected) pane
    var isActivePane: Bool = false {
        didSet { updateStateVisuals() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .secondarySystemBackground

        // State dot
        stateDot.layer.cornerRadius = 3.5
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateDot)

        // Title
        titleLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = "shell"
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Focus (maximize) button — expand arrows icon
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        focusButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: iconConfig), for: .normal)
        focusButton.tintColor = .secondaryLabel
        focusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(focusButton)

        // Menu button — ellipsis icon
        menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: iconConfig), for: .normal)
        menuButton.tintColor = .secondaryLabel
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuButton)

        NSLayoutConstraint.activate([
            stateDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stateDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateDot.widthAnchor.constraint(equalToConstant: 7),
            stateDot.heightAnchor.constraint(equalToConstant: 7),

            titleLabel.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: focusButton.leadingAnchor, constant: -4),

            focusButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -2),
            focusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            focusButton.widthAnchor.constraint(equalToConstant: 22),
            focusButton.heightAnchor.constraint(equalToConstant: 22),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 22),
            menuButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        updateStateVisuals()
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
            backgroundColor = UIColor.tintColor.withAlphaComponent(0.10)
            titleLabel.textColor = .label
        } else {
            backgroundColor = .secondarySystemBackground
            titleLabel.textColor = .secondaryLabel
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
