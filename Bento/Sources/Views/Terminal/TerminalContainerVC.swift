import UIKit
import BentoTerminalCore
import SwiftTmux

/// Phases of a pane title-bar drag (tiled mode), reported to the parent so it can
/// resolve the pane under the finger and swap. Points are in WINDOW coordinates
/// (`gesture.location(in: nil)`) so the parent can hit-test across all panes.
/// Mirrors the macOS host's `PaneDragPhase` drag-to-swap.
enum TitleDragPhase {
    case began
    case moved(CGPoint)
    case ended(CGPoint)
    case cancelled
}

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

    /// User is dragging this pane's title bar (tiled mode) to swap it with the
    /// pane under the finger. Parent VC resolves the target and calls swapPanes.
    /// Mirrors the macOS host's title-bar drag-to-swap.
    var onTitleDrag: ((_ phase: TitleDragPhase) -> Void)?

    /// The surface reported its current size (cols × rows + cell px) after
    /// layout. Parent VC uses this to drive tmux client resize (refresh-client
    /// -C) and to learn the font cell size for tiling. Authoritative — any
    /// homemade cell-size math will drift from the engine's internal measurement
    /// and cause TUI wrap mismatches.
    var onSizeChanged: ((_ size: TerminalSurfaceSize) -> Void)?

    /// Tiled mode: the container owns sizing (it computes one tmux client size
    /// for the whole viewport and sizes each surface to its exact tmux cell
    /// geometry). When true this VC does NOT push its own size to tmux. Also
    /// drives the title bar's look (green chrome vs. blend into the terminal).
    var tiled = false {
        didSet { titleBar.isTiled = tiled }
    }

    /// In tiled mode, the exact surface size (points) = tmux cols×rows × cell,
    /// set by the container so ghostty's grid matches the tmux pane grid. nil =
    /// fill the available area (focus / single-pane).
    var fixedTerminalCellSize: CGSize? {
        didSet { view.setNeedsLayout() }
    }

    /// Title-strip height for focus / single-pane mode (a comfortable touch
    /// target). In tiled mode the host overrides `titleBarHeight` to one cell.
    static let defaultTitleBarHeight: CGFloat = 32

    /// Title-strip height (points). The host sets this per layout: one character
    /// cell in tiled mode — so the strip occupies tmux's divider row between
    /// stacked panes, exactly as the macOS host does (the gap↔title-bar-height
    /// constraint that keeps irregular splits aligned) — and `defaultTitleBarHeight`
    /// in focus / single-pane mode.
    var titleBarHeight: CGFloat = TerminalContainerVC.defaultTitleBarHeight {
        didSet { if oldValue != titleBarHeight { view.setNeedsLayout() } }
    }

    /// Horizontal inset (points) of the surface inside the container. In tiled
    /// mode the host grows each container half a cell into the divider column on
    /// each side so side-by-side panes meet on the divider centerline; the
    /// surface keeps its exact cell size, inset by this much. 0 = flush.
    var surfaceInsetX: CGFloat = 0 {
        didSet { if oldValue != surfaceInsetX { view.setNeedsLayout() } }
    }

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
        // Blend (non-tiled) mode tracks the terminal background; tiled mode
        // ignores this and uses its own green/gray chrome (see PaneTitleBar).
        titleBar.surfaceColor = bgColor
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let tbh = titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        if let fixed = fixedTerminalCellSize {
            // Cell-exact (tiled): inset by surfaceInsetX (half a divider cell) and
            // placed under the title bar; may overflow the tile by one cell on
            // purpose (clipped) so ghostty's grid >= tmux.
            surface.frame = CGRect(x: surfaceInsetX, y: tbh, width: fixed.width, height: fixed.height)
        } else {
            surface.frame = CGRect(x: 0, y: tbh, width: view.bounds.width,
                                   height: max(0, view.bounds.height - tbh))
        }
    }

    // MARK: - Setup

    private func setupTitleBar() {
        let tbh = titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        titleBar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        titleBar.surfaceColor = view.backgroundColor ?? STTheme.term.bg
        // The title bar is now just [● state-dot] [title]. Zoom + the pane menu
        // live on the floating toolbar (the strip is one cell tall in tiled
        // mode — too short to host touch targets). See `paneMenu` / onToggleZoom.
        view.addSubview(titleBar)

        // Drag the title bar onto another pane to swap them (tiled mode), exactly
        // like the macOS host. The parent resolves the target under the finger.
        let titleDrag = UIPanGestureRecognizer(target: self, action: #selector(handleTitleDrag(_:)))
        titleBar.addGestureRecognizer(titleDrag)
    }

    @objc private func handleTitleDrag(_ g: UIPanGestureRecognizer) {
        // Window coordinates so the parent can hit-test across every pane.
        let win = g.location(in: nil)
        switch g.state {
        case .began:   onTitleDrag?(.began)
        case .changed: onTitleDrag?(.moved(win))
        case .ended:   onTitleDrag?(.ended(win))
        default:       onTitleDrag?(.cancelled)
        }
    }

    /// Drag-to-swap highlight: when true, this pane is the drop target and gets an
    /// accent border (restored to the normal active/inactive border on release).
    /// Mirrors the macOS `PaneCellView.isSwapTarget`.
    var isSwapTarget: Bool = false {
        didSet { if oldValue != isSwapTarget { applyPaneBorder(active: paneIsActive) } }
    }

    /// The pane's action menu (Split / Rename / Profile / Close), rebuilt on
    /// each access so it reflects current state. Hosted by the floating toolbar.
    var paneMenu: UIMenu { makePaneMenu() }

    private func setupSurface() {
        let tbh = titleBarHeight
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
            hideSelectionHandles()
            return
        }
        onSelectPaneTapped?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if keyboardMode {
            // Typing → double-tap selects the word (standard iOS behavior); it
            // no longer dismisses the keyboard (use the accessory ⌄ button).
            let p = gesture.location(in: surface)
            if surface.selectWord(at: p) {
                refreshSelectionHandles()
                presentEditMenu(at: p)
            }
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
                hideSelectionHandles()
                surface.selectionBegin(at: p)
            case .changed:
                surface.selectionExtend(to: p)
            case .ended:
                isSelecting = false
                surface.selectionEnd()
                if surface.hasSelection {
                    refreshSelectionHandles()
                    presentEditMenu(at: p)
                }
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

    // MARK: - Selection handles (PRD §3.8)

    private var startHandle: SelectionHandle?
    private var endHandle: SelectionHandle?
    /// Cached selection extent in `view` coordinates: start = top-left corner,
    /// end = bottom-right corner. Used to re-anchor while dragging a handle.
    private var selStartCorner: CGPoint?
    private var selEndCorner: CGPoint?

    /// Number of terminal columns a string occupies on one line (CJK/wide → 2).
    private func displayColumns(of s: Substring) -> Int {
        var n = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF) ||
                       (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF) ||
                       (v >= 0xFF00 && v <= 0xFF60) || (v >= 0x1F300 && v <= 0x1FAFF)
            n += wide ? 2 : 1
        }
        return n
    }

    /// Show / reposition the two draggable selection handles from the engine's
    /// current selection geometry. Hides them when there's no selection or the
    /// keyboard is down (selection only exists in keyboard mode).
    private func refreshSelectionHandles() {
        guard keyboardMode, surface.hasSelection, let geo = surface.selectionGeometry() else {
            hideSelectionHandles()
            return
        }
        let off = surface.frame.origin            // surface sits below the title bar
        let cell = geo.cell
        let startCorner = CGPoint(x: geo.topLeft.x + off.x, y: geo.topLeft.y + off.y)

        // ghostty only reports the selection's top-left, so derive the end:
        // single line → start + text width; multi-line → last line width, N rows
        // down (approximate, but the handle becomes exact once dragged).
        let text = surface.selectedText() ?? ""
        let endCorner: CGPoint
        if let nl = text.firstIndex(of: "\n") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let lastCols = displayColumns(of: lines.last ?? "")
            _ = nl
            endCorner = CGPoint(x: off.x + CGFloat(lastCols) * cell.width,
                                y: startCorner.y + CGFloat(lines.count) * cell.height)
        } else {
            endCorner = CGPoint(x: startCorner.x + CGFloat(displayColumns(of: text[...])) * cell.width,
                                y: startCorner.y + cell.height)
        }

        let start = ensureHandle(\.startHandle, isStart: true)
        let end = ensureHandle(\.endHandle, isStart: false)
        start.cellHeight = cell.height
        end.cellHeight = cell.height
        start.positionStemTop(CGPoint(x: startCorner.x, y: startCorner.y))
        end.positionStemTop(CGPoint(x: endCorner.x, y: endCorner.y - cell.height))
        view.bringSubviewToFront(start)
        view.bringSubviewToFront(end)
        start.isHidden = false
        end.isHidden = false
        selStartCorner = startCorner
        selEndCorner = endCorner
    }

    private func ensureHandle(_ keyPath: ReferenceWritableKeyPath<TerminalContainerVC, SelectionHandle?>,
                              isStart: Bool) -> SelectionHandle {
        if let h = self[keyPath: keyPath] { return h }
        let h = SelectionHandle(isStart: isStart)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionHandlePan(_:)))
        h.addGestureRecognizer(pan)
        view.addSubview(h)
        self[keyPath: keyPath] = h
        return h
    }

    private func hideSelectionHandles() {
        startHandle?.isHidden = true
        endHandle?.isHidden = true
        selStartCorner = nil
        selEndCorner = nil
    }

    @objc private func handleSelectionHandlePan(_ g: UIPanGestureRecognizer) {
        guard let handle = g.view as? SelectionHandle,
              let cell = surface.selectionGeometry()?.cell,
              let startCorner = selStartCorner, let endCorner = selEndCorner else { return }

        // Anchor at the cell center of the OTHER (fixed) end; extend to the
        // finger, clamped into the surface.
        let fixedCorner = handle.isStart ? endCorner : startCorner
        let anchorView = handle.isStart
            ? CGPoint(x: fixedCorner.x - cell.width / 2, y: fixedCorner.y - cell.height / 2)
            : CGPoint(x: fixedCorner.x + cell.width / 2, y: fixedCorner.y - cell.height / 2)

        let p = g.location(in: view)
        let off = surface.frame.origin
        func toSurface(_ pt: CGPoint) -> CGPoint {
            CGPoint(x: min(max(pt.x - off.x, 1), surface.bounds.width - 1),
                    y: min(max(pt.y - off.y, 1), surface.bounds.height - 1))
        }

        switch g.state {
        case .began:
            surface.selectionBegin(at: toSurface(anchorView))
            surface.selectionExtend(to: toSurface(p))
        case .changed:
            surface.selectionExtend(to: toSurface(p))
            refreshSelectionHandles()
        case .ended, .cancelled, .failed:
            surface.selectionEnd()
            refreshSelectionHandles()
            if surface.hasSelection { presentEditMenu(at: p) }
        default:
            break
        }
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
        applyPaneBorder(active: active)

        let isSystem = ThemeStore.shared.current.id == TerminalColorTheme.systemID
        let bgColor = isSystem ? STTheme.paneBackground(for: state)
                               : ThemeStore.shared.current.bgColor
        UIView.animate(withDuration: 0.26) {
            self.view.backgroundColor = bgColor
            self.surface.backgroundColor = bgColor
            self.titleBar.surfaceColor = bgColor
        }
    }

    /// Accent green for the active tiled pane — the SAME color and border widths
    /// as the macOS host (`GhosttyPaneColors.accent`, applyBorder) so tiled panes
    /// look identical across platforms. Borders only show in tiled mode; a
    /// focused / single pane fills the screen and needs no frame.
    private static let activeBorderColor = UIColor(red: 0.20, green: 0.80, blue: 0.55, alpha: 1.0)
    private static let inactiveBorderColor = UIColor(white: 1, alpha: 0.10)

    /// Last-applied active state, so `isSwapTarget` can restore the right border
    /// when the drag ends.
    private var paneIsActive = false

    private func applyPaneBorder(active: Bool) {
        paneIsActive = active
        guard tiled else {
            view.layer.borderWidth = 0
            return
        }
        if isSwapTarget {
            view.layer.borderWidth = 2.5
            view.layer.borderColor = Self.activeBorderColor.cgColor
            return
        }
        view.layer.borderWidth = active ? 1.5 : 0.5
        view.layer.borderColor = (active ? Self.activeBorderColor : Self.inactiveBorderColor).cgColor
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

/// Minimal title bar sitting atop the terminal. Just a state dot + title — the
/// zoom + pane-menu actions moved to the floating toolbar (the strip is one
/// cell tall in tiled mode, too short for touch targets). Two looks:
///   • Tiled (multi-pane): chrome mirrors the macOS host — a dark-green band
///     with bright-green text when active, dark-gray with muted text otherwise.
///   • Single / focus: blends into the terminal background (no contrast band),
///     so a fullscreen pane reads as one continuous surface.
///
/// Layout: [● state-dot] [title……………………………………………]
final class PaneTitleBar: UIView {
    let titleLabel = UILabel()
    private let stateDot = UIView()

    /// Active / inactive chrome — the SAME values as the macOS host so tiled
    /// panes look identical across platforms.
    private static let activeBg    = UIColor(red: 0.12, green: 0.26, blue: 0.20, alpha: 1.0)
    private static let inactiveBg  = UIColor(white: 0.12, alpha: 1.0)
    private static let activeInk   = UIColor(red: 0.30, green: 0.90, blue: 0.62, alpha: 1.0)
    private static let inactiveInk = UIColor(white: 0.65, alpha: 1.0)

    /// Drives dot color and (when active) text emphasis.
    var paneState: PaneState = .idle {
        didSet { updateStateVisuals() }
    }

    /// Active state drives the green chrome (tiled) / text emphasis (blend).
    var isActivePane: Bool = false {
        didSet { updateChrome() }
    }

    /// Tiled mode → macOS-style green/gray chrome; otherwise blend into the
    /// terminal background (`surfaceColor`).
    var isTiled: Bool = false {
        didSet { if oldValue != isTiled { updateChrome() } }
    }

    /// Terminal background, used only in blend (non-tiled) mode so a fullscreen
    /// pane's title bar flows into the terminal. Ignored in tiled mode.
    var surfaceColor: UIColor = STTheme.term.bg {
        didSet { if !isTiled { backgroundColor = surfaceColor } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // In tiled mode the strip is only one character cell tall; clip so the
        // centered dot never spills onto the terminal surface below.
        clipsToBounds = true

        stateDot.layer.cornerRadius = 4
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateDot)

        titleLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = "shell"
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            stateDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stateDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateDot.widthAnchor.constraint(equalToConstant: 8),
            stateDot.heightAnchor.constraint(equalToConstant: 8),

            titleLabel.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])

        updateChrome()
    }

    /// Tiled: active = dark-green band + bright-green text, inactive = dark-gray
    /// band + muted text (mirrors the macOS host). Blend: title bar takes the
    /// terminal background, text brightens only when active.
    private func updateChrome() {
        if isTiled {
            backgroundColor = isActivePane ? Self.activeBg : Self.inactiveBg
            titleLabel.textColor = isActivePane ? Self.activeInk : Self.inactiveInk
        } else {
            backgroundColor = surfaceColor
            titleLabel.textColor = isActivePane ? .label : .secondaryLabel
        }
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// An iOS-style text-selection handle: a thin stem one cell tall with a round
/// knob at one end — top for the selection start, bottom for the end (PRD §3.8).
/// The view is padded by `inset` on every side so the small knob is easy to grab.
final class SelectionHandle: UIView {
    let isStart: Bool
    var cellHeight: CGFloat = 16 { didSet { setNeedsDisplay() } }
    private static let inset: CGFloat = 18
    private let knobRadius: CGFloat = 5.5
    private let stemWidth: CGFloat = 2

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Place the view so its stem starts at `stemTop` (superview coords) and
    /// runs down one cell.
    func positionStemTop(_ stemTop: CGPoint) {
        let i = Self.inset
        frame = CGRect(x: stemTop.x - i, y: stemTop.y - i,
                       width: i * 2, height: cellHeight + i * 2)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(STTheme.ChromeDark.accent.cgColor)
        let cx = bounds.midX
        let top = Self.inset
        ctx.fill(CGRect(x: cx - stemWidth / 2, y: top, width: stemWidth, height: cellHeight))
        let knobY = isStart ? top : top + cellHeight
        ctx.fillEllipse(in: CGRect(x: cx - knobRadius, y: knobY - knobRadius,
                                   width: knobRadius * 2, height: knobRadius * 2))
    }
}
