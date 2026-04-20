import UIKit
import SwiftTerm

/// Hosts a single SwiftTerm TerminalView for one pane.
/// In Phase 2, multiple instances of this exist — one per tmux pane.
final class TerminalContainerVC: UIViewController {
    private(set) var terminalView: TerminalView!
    private let accessoryView = KeyboardAccessoryView()

    /// For tmux mode: the pane VM that owns this terminal
    var paneVM: PaneViewModel?

    /// For non-tmux fallback: the terminal VM
    var terminalVM: TerminalViewModel?

    /// Tap callbacks (set by MultiPaneContainerVC)
    var onSingleTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?

    /// Voice long-press callback (location updates for direction detection)
    var onLongPress: ((UIGestureRecognizer.State, CGPoint) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupTerminalView()
        setupTapGestures()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        terminalView.frame = view.bounds
    }

    private func setupTerminalView() {
        terminalView = TerminalView(frame: view.bounds)
        terminalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminalView.terminalDelegate = self
        terminalView.nativeBackgroundColor = .black
        terminalView.nativeForegroundColor = .white

        let fontSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 14 : 12
        terminalView.font = UIFont(name: "Menlo", size: fontSize)
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        terminalView.inputAccessoryView = accessoryView
        accessoryView.onKeyTap = { [weak self] key in
            self?.handleAccessoryKey(key)
        }

        view.addSubview(terminalView)
    }

    private func setupTapGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self

        singleTap.require(toFail: doubleTap)

        // Long-press for voice input (in voice mode)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.2
        longPress.delegate = self

        terminalView.addGestureRecognizer(singleTap)
        terminalView.addGestureRecognizer(doubleTap)
        terminalView.addGestureRecognizer(longPress)
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap() {
        onDoubleTap?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: gesture.view)
        onLongPress?(gesture.state, location)
    }

    /// Wire this terminal to a PaneViewModel (tmux mode)
    func bindToPaneVM(_ vm: PaneViewModel) {
        self.paneVM = vm
        vm.onDataReceived = { [weak self] data in
            DispatchQueue.main.async {
                let bytes = ArraySlice<UInt8>(data)
                self?.terminalView.feed(byteArray: bytes)
            }
        }
    }

    /// Wire this terminal to TerminalViewModel (non-tmux fallback)
    func bindToTerminalVM(_ vm: TerminalViewModel) {
        self.terminalVM = vm
        vm.onRawDataReceived = { [weak self] data in
            DispatchQueue.main.async {
                let bytes = ArraySlice<UInt8>(data)
                self?.terminalView.feed(byteArray: bytes)
            }
        }
    }

    /// Get the current terminal size in cols/rows
    var terminalSize: (cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminal.cols, terminal.rows)
    }

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

// MARK: - TerminalViewDelegate

// MARK: - UIGestureRecognizerDelegate

extension TerminalContainerVC: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true // Allow our taps to work alongside SwiftTerm's gestures
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
    func setTerminalTitle(source: TerminalView, title: String) {}

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if paneVM == nil {
            // Only resize SSH PTY in non-tmux mode
            terminalVM?.resizeTerminal(cols: newCols, rows: newRows)
        }
        // In tmux mode: SwiftTerm should match tmux pane size, not the other way around
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
