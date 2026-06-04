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

    /// User renamed this pane to `newTitle` (via the pane menu).
    var onRename: ((_ newTitle: String) -> Void)?

    /// User picked a detection profile for this pane (nil = auto-detect).
    var onSetProfile: ((_ profileID: String?) -> Void)?

    /// Current forced profile id for this pane (nil = auto), for the menu check.
    var currentProfileID: (() -> String?)?

    /// The surface reported its current size (cols × rows + cell px) after
    /// layout. Parent VC uses this to drive tmux client resize (refresh-client
    /// -C) and to learn the font cell size for tiling. Authoritative — any
    /// homemade cell-size math will drift from the engine's internal measurement
    /// and cause TUI wrap mismatches.
    var onSizeChanged: ((_ size: TerminalSurfaceSize) -> Void)?

    /// Tiled mode: the container owns sizing (it computes one tmux client size
    /// for the whole viewport and sizes each surface to its exact tmux cell
    /// geometry). When true this VC does NOT push its own size to tmux.
    var tiled = false

    /// In tiled mode, the exact surface size (points) = tmux cols×rows × cell,
    /// set by the container so ghostty's grid matches the tmux pane grid. nil =
    /// fill the available area (focus / single-pane).
    var fixedTerminalCellSize: CGSize? {
        didSet { view.setNeedsLayout() }
    }

    private static let titleBarHeight: CGFloat = 32
    /// Public accessor for layout math in the container.
    static var titleBarHeightValue: CGFloat { titleBarHeight }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term.bg
        // Tiled mode sizes the surface one cell larger than the pane (see the
        // container) so ghostty doesn't drop a column; clip the overflow.
        view.clipsToBounds = true
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
        // NOTE: surface teardown is NOT done here — deinit is unreliable (and
        // can't touch MainActor state). Callers invoke teardown() explicitly
        // before the view leaves the hierarchy.
    }

    /// Stop rendering and free this pane's ghostty surface on the main thread,
    /// BEFORE the view/layer is torn down. Must be called explicitly when the
    /// pane is closed or the screen is dismissed — relying on deinit is unsafe
    /// (the display link keeps drawing into a half-freed Metal layer → crash).
    func teardown() {
        surface?.teardown()
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
        if let fixed = fixedTerminalCellSize {
            // Cell-exact (tiled): top-left under the title bar; may overflow the
            // tile by one cell on purpose (clipped) so ghostty's grid >= tmux.
            surface.frame = CGRect(x: 0, y: tbh, width: fixed.width, height: fixed.height)
        } else {
            surface.frame = CGRect(x: 0, y: tbh, width: view.bounds.width,
                                   height: max(0, view.bounds.height - tbh))
        }
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
            // Tiled mode: the container owns the tmux client size; a pane never
            // pushes its own (its surface is deliberately sized to a fixed cell
            // geometry). Still forward the metrics so the container can learn
            // the cell pixel size.
            if !self.tiled, self.paneVM == nil {
                self.terminalVM?.resizeTerminal(cols: size.columns, rows: size.rows)
            }
            self.onSizeChanged?(size)
        }
        surface.onTitleChanged = { [weak self] title in
            self?.updateTitle(title)
        }

        surface.inputAccessoryView = accessoryView
        accessoryView.onKeyTap = { [weak self] key in
            self?.handleAccessoryKey(key)
        }
        // Dismiss-keyboard button on the accessory bar (double-tap no longer
        // dismisses — it selects text in keyboard mode).
        accessoryView.onDismissKeyboard = { [weak self] in
            self?.surface.resignFirstResponder()
        }

        // Native edit menu (Copy / Select All) for text selection.
        surface.addInteraction(editMenuInteraction)

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

        // Single-finger immediate drag → scrollback (PRD §3.1/§3.7). The voice
        // press fails on early movement (its 6pt slop), so a drag scrolls while
        // a still hold records — no extra coordination needed beyond ignoring
        // scroll while voice is actively recording.
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 1
        scrollPan.maximumNumberOfTouches = 1
        scrollPan.delegate = self
        surface.addGestureRecognizer(scrollPan)
    }

    private var lastScrollPoint: CGPoint = .zero
    /// True while a long-press text selection drag is in progress (suppresses
    /// scroll). Only happens in keyboard mode.
    private var isSelecting = false

    /// Keyboard-up mode: when the surface is first responder we behave like a
    /// normal iOS text view — double-tap/long-press select text instead of
    /// summoning the keyboard / recording voice. Keyboard is dismissed via the
    /// accessory bar button, not by double-tap.
    private var keyboardMode: Bool { surface.isFirstResponder }

    @objc private func handleScrollPan(_ g: UIPanGestureRecognizer) {
        // Don't scroll while voice recording or while a selection drag is active.
        if voiceController?.isRecording == true || isSelecting { return }
        let p = g.location(in: surface)
        switch g.state {
        case .began:
            lastScrollPoint = p
        case .changed:
            let dy = p.y - lastScrollPoint.y
            let dx = p.x - lastScrollPoint.x
            lastScrollPoint = p
            // Finger down (dy>0) reveals older scrollback — natural touch paging.
            surface.scroll(deltaX: dx, deltaY: dy, at: p)
        default:
            break
        }
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        // A tap clears an active selection (like iOS) before anything else.
        if keyboardMode, surface.hasSelection {
            surface.clearSelection(at: gesture.location(in: surface))
            return
        }
        onSelectPaneTapped?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if keyboardMode {
            // Typing → double-tap selects the word (standard iOS behavior); it
            // no longer dismisses the keyboard (use the accessory ⌄ button).
            let p = gesture.location(in: surface)
            if surface.selectWord(at: p) { presentEditMenu(at: p) }
        } else {
            _ = surface.becomeFirstResponder()
        }
    }

    @objc private func handleVoicePress(_ gesture: VoicePressGesture) {
        // Keyboard mode: long-press starts a drag text selection (not voice).
        if keyboardMode {
            let p = gesture.currentLocation()
            switch gesture.state {
            case .began:
                isSelecting = true
                surface.selectionBegin(at: p)
            case .changed:
                surface.selectionExtend(to: p)
            case .ended:
                isSelecting = false
                surface.selectionEnd()
                if surface.hasSelection { presentEditMenu(at: p) }
            case .cancelled, .failed:
                isSelecting = false
                surface.selectionEnd()
            default:
                break
            }
            return
        }

        // Keyboard down: long-press = voice.
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

    // MARK: - Text selection edit menu

    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)

    private func presentEditMenu(at point: CGPoint) {
        let cfg = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenuInteraction.presentEditMenu(with: cfg)
    }

    private func copySelection() {
        guard let text = surface.selectedText(), !text.isEmpty else { return }
        UIPasteboard.general.string = text
        HapticService.shared.sent()
        showCopyToast()
    }

    private func showCopyToast() {
        let label = UILabel()
        label.text = "  Copied  "
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.78)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            label.heightAnchor.constraint(equalToConstant: 30),
        ])
        UIView.animate(withDuration: 0.18, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: 0.9, options: [],
                           animations: { label.alpha = 0 },
                           completion: { _ in label.removeFromSuperview() })
        }
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
            UIAction(title: "Rename",
                     image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.presentRenamePrompt()
            },
            makeProfileMenu(),
            UIAction(title: "Close Pane",
                     image: UIImage(systemName: "xmark"),
                     attributes: .destructive) { [weak self] _ in
                self?.onCloseRequested?()
            },
        ])
    }

    /// Pane menu → Change Profile (PRD §3.5). Built lazily each time the menu
    /// opens so the checkmark reflects the current override; "Auto" clears it.
    private func makeProfileMenu() -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            let current = self.currentProfileID?()
            var items: [UIMenuElement] = [
                UIAction(title: "Auto (detect)", state: current == nil ? .on : .off) { [weak self] _ in
                    self?.onSetProfile?(nil)
                }
            ]
            for profile in ProfileStore.shared.profiles {
                items.append(UIAction(title: profile.name,
                                      state: current == profile.id ? .on : .off) { [weak self] _ in
                    self?.onSetProfile?(profile.id)
                })
            }
            completion(items)
        }
        return UIMenu(title: "Profile",
                      image: UIImage(systemName: "slider.horizontal.3"),
                      children: [deferred])
    }

    /// Pane menu → Rename: prompt for a new pane title, prefilled with the
    /// current one. Submitting routes through `onRename` to the view model.
    private func presentRenamePrompt() {
        let alert = UIAlertController(title: "Rename Pane", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            tf.text = self?.paneVM?.pane.title
            tf.placeholder = "Pane title"
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            self?.onRename?(text)
        })
        present(alert, animated: true)
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

// MARK: - UIEditMenuInteractionDelegate (text selection menu)

extension TerminalContainerVC: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var items: [UIMenuElement] = []
        if surface.hasSelection {
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
            })
        }
        items.append(UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
            guard let self else { return }
            self.surface.selectAll()
            if self.surface.hasSelection { self.copySelectionMenuReshow() }
        })
        return UIMenu(children: items)
    }

    /// After Select All, re-show the menu so Copy is available on the new selection.
    private func copySelectionMenuReshow() {
        let p = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        DispatchQueue.main.async { [weak self] in self?.presentEditMenu(at: p) }
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
