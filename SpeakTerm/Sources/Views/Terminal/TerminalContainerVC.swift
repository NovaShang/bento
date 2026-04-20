import UIKit
import SwiftTerm

/// Hosts a single SwiftTerm TerminalView for one pane, with a title bar.
///
/// Gesture behavior is mode-dependent:
/// - Voice mode: tap=switch pane (no keyboard), long-press=voice, scroll=history
/// - Keyboard mode: tap=switch+keyboard, scroll=history
final class TerminalContainerVC: UIViewController {
    private(set) var terminalView: TerminalView!
    private let accessoryView = KeyboardAccessoryView()
    private let titleBar = PaneTitleBar()

    /// For tmux mode: the pane VM that owns this terminal
    var paneVM: PaneViewModel?

    /// For non-tmux fallback: the terminal VM
    var terminalVM: TerminalViewModel?

    // MARK: - Callbacks (set by MultiPaneContainerVC)

    var onSingleTap: (() -> Void)?
    var onFocusTap: (() -> Void)?  // title bar ⛶ button
    var onLongPress: ((UIGestureRecognizer.State, CGPoint) -> Void)?

    /// Current input mode — controls gesture behavior
    var inputMode: InputMode = .voice {
        didSet { updateGesturesForMode() }
    }

    private var ourLongPress: UILongPressGestureRecognizer?
    private static let titleBarHeight: CGFloat = 24

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupTitleBar()
        setupTerminalView()
        setupGestures()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let tbh = Self.titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        terminalView.frame = CGRect(x: 0, y: tbh, width: view.bounds.width, height: view.bounds.height - tbh)
    }

    // MARK: - Title Bar

    private func setupTitleBar() {
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: Self.titleBarHeight)
        titleBar.autoresizingMask = [.flexibleWidth]
        titleBar.onFocusTap = { [weak self] in
            self?.onFocusTap?()
        }
        view.addSubview(titleBar)
    }

    func updateTitle(_ title: String) {
        titleBar.titleLabel.text = title
    }

    // MARK: - Terminal View

    private func setupTerminalView() {
        let tbh = Self.titleBarHeight
        terminalView = TerminalView(frame: CGRect(x: 0, y: tbh, width: view.bounds.width, height: view.bounds.height - tbh))
        terminalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminalView.terminalDelegate = self
        terminalView.nativeBackgroundColor = .black
        terminalView.nativeForegroundColor = .white

        let fontSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 14 : 12
        terminalView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        terminalView.inputAccessoryView = accessoryView
        accessoryView.onKeyTap = { [weak self] key in
            self?.handleAccessoryKey(key)
        }

        view.addSubview(terminalView)
    }

    // MARK: - Gestures

    private func setupGestures() {
        // Single tap on terminal: switch pane (+ keyboard in keyboard mode)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self
        terminalView.addGestureRecognizer(singleTap)

        // Long-press for voice input (voice mode only)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.2
        longPress.delegate = self
        ourLongPress = longPress
        terminalView.addGestureRecognizer(longPress)

        // Disable SwiftTerm's native long-press (text selection menu)
        // after our gestures are added so we can identify ours by delegate
        DispatchQueue.main.async { [weak self] in
            self?.disableTerminalViewNativeGestures()
        }

        updateGesturesForMode()
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
        if inputMode == .voice {
            terminalView.resignFirstResponder()
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: gesture.view)
        onLongPress?(gesture.state, location)
    }

    private func disableTerminalViewNativeGestures() {
        guard let recognizers = terminalView.gestureRecognizers else { return }
        for recognizer in recognizers {
            if recognizer.delegate === self { continue }
            if recognizer is UILongPressGestureRecognizer {
                recognizer.isEnabled = false
            }
        }
        for interaction in terminalView.interactions {
            if interaction is UIEditMenuInteraction {
                terminalView.removeInteraction(interaction)
            }
        }
    }

    private func updateGesturesForMode() {
        ourLongPress?.isEnabled = (inputMode == .voice)
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
        if let paneVM {
            paneVM.sendInput(data)
        } else {
            terminalVM?.sendData(data)
        }
    }

    private func sendString(_ string: String) {
        if let paneVM {
            paneVM.sendString(string)
        } else {
            terminalVM?.sendString(string)
        }
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

// MARK: - UIGestureRecognizerDelegate

extension TerminalContainerVC: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
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
    func setTerminalTitle(source: TerminalView, title: String) {
        updateTitle(title)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if paneVM == nil {
            terminalVM?.resizeTerminal(cols: newCols, rows: newRows)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let string = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = string
        }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

// MARK: - Pane Title Bar

/// Compact title bar at the top of each pane: shows command name + focus button
final class PaneTitleBar: UIView {
    let titleLabel = UILabel()
    private let focusButton = UIButton(type: .system)

    var onFocusTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.12, alpha: 1)

        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .lightGray
        titleLabel.text = "shell"
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        focusButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10)), for: .normal)
        focusButton.tintColor = .lightGray
        focusButton.translatesAutoresizingMaskIntoConstraints = false
        focusButton.addAction(UIAction { [weak self] _ in
            self?.onFocusTap?()
        }, for: .touchUpInside)
        addSubview(focusButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: focusButton.leadingAnchor, constant: -4),

            focusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            focusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            focusButton.widthAnchor.constraint(equalToConstant: 24),
            focusButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
