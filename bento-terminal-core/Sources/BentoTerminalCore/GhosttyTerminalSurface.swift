#if canImport(UIKit)
import UIKit
import GhosttyKit

/// A libghostty-backed terminal surface for iOS. The view is a CAMetalLayer that
/// libghostty renders into directly; we feed it remote bytes via
/// `ghostty_surface_process_output` and it emits encoded keystrokes back through
/// the runtime's `write_to_host` callback (the "external backend" path — no local
/// PTY, which iOS forbids). Host code (TerminalContainerVC) treats this purely
/// through the `TerminalSurface` protocol.
public final class GhosttyTerminalSurface: UIView, TerminalSurface, UIKeyInput, UITextInputTraits {

    // MARK: TerminalSurface callbacks
    public var onInput: ((Data) -> Void)?
    public var onSizeChanged: ((TerminalSurfaceSize) -> Void)?
    public var onTitleChanged: ((String) -> Void)?
    public private(set) var currentSize: TerminalSurfaceSize?

    private var surface: ghostty_surface_t?
    private var theme: TerminalTheme
    private var renderLink: CADisplayLink?
    private var pendingBytes: [Data] = []
    /// Set once teardown() runs; blocks any later surface (re)creation so a
    /// stray layout/window callback can't resurrect a freed surface.
    private var isTornDown = false

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public init(theme: TerminalTheme) {
        self.theme = theme
        // Non-zero initial frame so the Metal layer can size itself before layout.
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        isOpaque = true
        backgroundColor = UIColor(rgb: theme.background)
        isMultipleTouchEnabled = true
        contentScaleFactor = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        renderLink?.invalidate()
        renderLink = nil
        if let surface { ghostty_surface_free(surface) }
        surface = nil
    }

    /// Stop rendering and free the ghostty surface NOW, before the view/layer is
    /// torn down. The CADisplayLink keeps firing `ghostty_surface_draw` every
    /// frame; if the host view is removed (e.g. the session is dismissed) while
    /// the link is still live, the next draw commits a Metal/CoreAnimation
    /// transaction against the half-freed layer and aborts the process
    /// (renderer.Metal.initTarget → MTLTextureDescriptor validation). Mirrors the
    /// macOS host's teardown(). Idempotent.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        renderLink?.invalidate()
        renderLink = nil
        if let surface { ghostty_surface_free(surface) }
        surface = nil
    }

    // MARK: - Lifecycle / surface creation

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            createSurfaceIfNeeded()
            synchronizeGhosttyLayerGeometry()
            updateSurfaceSize()
            startRenderLink()
        } else {
            // Left the hierarchy — stop drawing so we never render into a layer
            // that's being torn down (Metal abort). The surface is freed in
            // teardown()/deinit.
            renderLink?.invalidate()
            renderLink = nil
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        createSurfaceIfNeeded()
        synchronizeGhosttyLayerGeometry()
        updateSurfaceSize()
    }

    /// ghostty attaches its Metal render layer as a SUBLAYER of this view's
    /// layer on iOS. We must size that sublayer to our bounds and set the
    /// content scale, or it renders into a zero/unscaled drawable and nothing
    /// is visible. (macOS doesn't need this — ghostty owns the whole layer there.)
    private func synchronizeGhosttyLayerGeometry() {
        let hostBounds = layer.bounds
        let scale = currentScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = hostBounds
            sublayer.contentsScale = scale
            sublayer.setNeedsDisplay()
        }
        CATransaction.commit()
    }

    private func createSurfaceIfNeeded() {
        guard !isTornDown,
              surface == nil,
              bounds.width > 0, bounds.height > 0,
              let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_IOS
        cfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(self).toOpaque()
        ))
        cfg.scale_factor = Double(currentScale)
        cfg.font_size = Float(theme.fontSize)
        cfg.wait_after_command = false

        guard let created = ghostty_surface_new(app, &cfg) else { return }
        surface = created

        synchronizeGhosttyLayerGeometry()
        updateSurfaceSize()
        ghostty_surface_set_focus(created, true)
        ghostty_surface_refresh(created)
        ghostty_surface_draw(created)
        startRenderLink()

        // Flush any bytes that arrived before the surface existed.
        let queued = pendingBytes
        pendingBytes.removeAll()
        for chunk in queued { feed(chunk) }
    }

    private var currentScale: CGFloat {
        let s = window?.screen.scale ?? traitCollection.displayScale
        return s > 0 ? s : UIScreen.main.scale
    }

    /// Metal's maximum 2D texture dimension (A-series GPUs). Exceeding it aborts
    /// in the Metal validation layer, so the render target must never be larger.
    private static let maxDrawableDimension: CGFloat = 16384

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = currentScale
        // Clamp the drawable to Metal's limits: a 0 or oversized texture aborts
        // the process in MTLTextureDescriptor validation. (A very large Pinned
        // page can otherwise overflow.)
        let wPx = min(max(bounds.width * scale, 1), Self.maxDrawableDimension)
        let hPx = min(max(bounds.height * scale, 1), Self.maxDrawableDimension)
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, UInt32(wPx), UInt32(hPx))
        ghostty_surface_refresh(surface)
        reportSizeIfNeeded()
    }

    private func reportSizeIfNeeded() {
        guard let surface else { return }
        let s = ghostty_surface_size(surface)
        let size = TerminalSurfaceSize(
            columns: Int(s.columns),
            rows: Int(s.rows),
            cellWidthPx: Int(s.cell_width_px),
            cellHeightPx: Int(s.cell_height_px)
        )
        guard size != currentSize, size.columns > 0, size.rows > 0 else { return }
        currentSize = size
        onSizeChanged?(size)
    }

    private func startRenderLink() {
        guard renderLink == nil, surface != nil, window != nil else { return }
        // Target a weak proxy, NOT self: CADisplayLink retains its target, so
        // `target: self` would be a retain cycle — the view would never deinit,
        // the link would keep firing draws forever (even off-screen), and a
        // teardown could never happen. The proxy holds the view weakly.
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        renderLink = link
    }

    fileprivate func renderTick() {
        // Never draw while detached from a window — the layer may be mid-teardown.
        guard let surface, window != nil else { return }
        ghostty_surface_draw(surface)
        // ghostty computes its cell grid a few frames after creation; poll so
        // onSizeChanged fires once it's non-zero (drives tmux/PTY resize).
        reportSizeIfNeeded()
    }

    // MARK: - TerminalSurface

    /// Scroll the terminal (scrollback / copy-mode) by a touch delta in points.
    /// ghostty applies scroll at the tracked mouse position, so we set that to
    /// the touch point first (a hard-won lesson from the macOS scrollWheel path —
    /// without mouse_pos the engine ignores the scroll). `precise` marks the
    /// delta as high-resolution (touch), matching trackpad behavior.
    public func scroll(deltaX: CGFloat, deltaY: CGFloat, at point: CGPoint) {
        guard let surface else { return }
        let p = pxPoint(point)
        ghostty_surface_mouse_pos(surface, p.0, p.1, GHOSTTY_MODS_NONE)
        // bit 0 = high-precision; momentum left at NONE (touch drag, not inertial).
        let mods: Int32 = 1
        // ghostty's precise-scroll path interprets the delta in DEVICE PIXELS —
        // it divides by the cell's pixel height to convert to rows. The pan
        // gesture reports finger movement in POINTS, so on a 2×/3× screen the
        // raw delta was 2-3× too small: you had to swipe several row-heights to
        // move one line. Scale points → pixels so scrolling tracks the finger 1:1.
        let s = Double(currentScale)
        ghostty_surface_mouse_scroll(surface, Double(deltaX) * s, Double(deltaY) * s, mods)
        ghostty_surface_refresh(surface)
    }

    // MARK: - Selection

    /// Mouse position for ghostty in LOGICAL POINTS (not backing pixels).
    /// ghostty applies the surface content scale internally, so multiplying by
    /// `currentScale` double-applies it — selection landed at 2× the row on
    /// Retina (click row n → selected row 2n−1). Matches the macOS surface.
    private func pxPoint(_ point: CGPoint) -> (Double, Double) {
        return (Double(point.x), Double(point.y))
    }

    // Selection logic is shared with macOS via `GhosttySel` — these are thin
    // forwarders that supply the surface handle and view-point→pixel conversion.

    /// Select the word under `point`. Returns whether a selection now exists.
    @discardableResult
    public func selectWord(at point: CGPoint) -> Bool {
        guard let surface else { return false }
        return GhosttySel.selectWord(surface, px: tuplePx(point))
    }

    /// Begin a drag selection (anchor) at `point`.
    public func selectionBegin(at point: CGPoint) {
        guard let surface else { return }
        GhosttySel.begin(surface, px: tuplePx(point))
    }

    /// Extend the in-progress drag selection to `point`.
    public func selectionExtend(to point: CGPoint) {
        guard let surface else { return }
        GhosttySel.extend(surface, px: tuplePx(point))
    }

    /// Finish the drag selection.
    public func selectionEnd() {
        guard let surface else { return }
        GhosttySel.end(surface)
    }

    public var hasSelection: Bool {
        guard let surface else { return false }
        return GhosttySel.hasSelection(surface)
    }

    /// Geometry for laying out selection handles: the selection's top-left in
    /// THIS view's points, and the cell size in points. nil if no selection.
    /// ghostty reports tl_px and the cell size in device pixels, so both divide
    /// by the content scale (the input mouse path is unscaled points — ghostty
    /// scales internally — but the read-back pixel fields are device pixels).
    public func selectionGeometry() -> (topLeft: CGPoint, cell: CGSize)? {
        guard let surface, let size = currentSize,
              let tl = GhosttySel.selectionTopLeftPx(surface) else { return nil }
        let s = currentScale
        guard s > 0 else { return nil }
        return (CGPoint(x: tl.x / s, y: tl.y / s),
                CGSize(width: CGFloat(size.cellWidthPx) / s,
                       height: CGFloat(size.cellHeightPx) / s))
    }

    /// The currently selected text, or nil.
    public func selectedText() -> String? {
        guard let surface else { return nil }
        return GhosttySel.selectedText(surface)
    }

    /// Select the entire scrollback/screen via the ghostty keybind action.
    @discardableResult
    public func selectAll() -> Bool {
        guard let surface else { return false }
        return GhosttySel.selectAll(surface)
    }

    /// Clear any selection (a plain left click collapses it).
    public func clearSelection(at point: CGPoint? = nil) {
        guard let surface else { return }
        GhosttySel.clear(surface, px: point.map { tuplePx($0) })
    }

    private func tuplePx(_ point: CGPoint) -> (x: Double, y: Double) {
        let (x, y) = pxPoint(point)
        return (x, y)
    }

    public func feed(_ data: Data) {
        guard let surface else { pendingBytes.append(data); return }
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: CChar.self).baseAddress else { return }
            ghostty_surface_process_output(surface, ptr, UInt(data.count))
        }
        ghostty_surface_refresh(surface)
    }

    public func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        backgroundColor = UIColor(rgb: theme.background)
        // Font size / family are applied at surface creation via config. A live
        // change recreates the surface so the new metrics take effect.
        if surface != nil, abs(theme.fontSize - Double(lastAppliedFontSize)) > 0.01 {
            recreateSurface()
        }
        lastAppliedFontSize = Float(theme.fontSize)
    }

    private var lastAppliedFontSize: Float = 0

    private func recreateSurface() {
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        currentSize = nil
        createSurfaceIfNeeded()
    }

    public func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    /// Called by GhosttyRuntime when the engine has bytes for the host (SSH).
    func handleHostWrite(_ data: Data) {
        onInput?(data)
    }

    /// Called by GhosttyRuntime on every SCROLLBAR action. iOS scroll-review-
    /// compose is a follow-up; no-op for now so the cross-platform runtime
    /// routing compiles on iOS.
    func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64) {}

    /// Called by GhosttyRuntime on GHOSTTY_ACTION_RENDER (and macOS's dirty
    /// sources). The iOS surface has no dirty-gate to mark — its CADisplayLink
    /// (`renderTick`) already calls `ghostty_surface_draw` every frame — so this
    /// is a no-op that just lets the cross-platform runtime compile on iOS.
    func setNeedsDraw() {}

    // Per-surface engine actions — no-ops on iOS (no pointer cursor / hover).
    func handleMouseShape(_ shape: ghostty_action_mouse_shape_e) {}
    func handleMouseVisibility(_ visible: Bool) {}
    func handleMouseOverLink(_ url: String?) {}

    // MARK: - Input (UIKeyInput)

    public override var canBecomeFirstResponder: Bool { true }
    public var hasText: Bool { true }

    // ghostty_surface_key (used for hardware keys below) is ignored unless the
    // surface is focused, so keep ghostty's focus in sync with first-responder
    // status. (ghostty_surface_text / insertText doesn't need this, which is why
    // soft-keyboard text worked even without it.)
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }

    @discardableResult
    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    private var _inputAccessoryView: UIView?
    public override var inputAccessoryView: UIView? {
        get { _inputAccessoryView }
        set { _inputAccessoryView = newValue }
    }
    // `.default`, NOT `.asciiCapable`: the ASCII keyboard hides the 🌐 globe key,
    // so non-Latin input methods (CJK, etc.) can't be reached — and CJK input is
    // a core use case. The IME-commit path already works (insertText routes
    // printable runs through ghostty_surface_text, which honors IME composition).
    public var keyboardType: UIKeyboardType = .default
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no

    public func insertText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        // The soft keyboard delivers Enter as "\n" (LF), but a terminal expects
        // CR (0x0d) to run the line — zsh/readline's line editor only accepts
        // the line on CR.
        //
        // We CANNOT just rewrite "\n" -> "\r" and feed it through
        // ghostty_surface_text: that channel is for printable text, and ghostty
        // drops the bare CR control byte instead of emitting it to the host, so
        // Enter appears to do nothing (the line never runs). Instead, split the
        // input — printable runs still go through ghostty (so per-mode encoding
        // and IME keep working) while each newline is written to the host
        // directly as CR, the same proven path deleteBackward() and the
        // accessory Enter key (sendString("\r")) already use.
        var run = ""
        func flushRun() {
            guard !run.isEmpty else { return }
            let bytes = Array(run.utf8)
            bytes.withUnsafeBufferPointer { buf in
                buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                    ghostty_surface_text(surface, ptr, UInt(buf.count))
                }
            }
            run = ""
        }
        for ch in text {
            if ch == "\n" || ch == "\r" {
                flushRun()
                onInput?(Data([0x0d]))
            } else {
                run.append(ch)
            }
        }
        flushRun()
    }

    public func deleteBackward() {
        onInput?(Data([0x7f]))
    }

    // Hardware keys (arrows / Enter / Ctrl chords / function keys) arrive as
    // UIPress, not insertText. Route through ghostty_surface_key so the engine
    // encodes them (needs focus — handled above).
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwardPresses(presses, action: GHOSTTY_ACTION_PRESS) { return }
        super.pressesBegan(presses, with: event)
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwardPresses(presses, action: GHOSTTY_ACTION_RELEASE) { return }
        super.pressesEnded(presses, with: event)
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwardPresses(presses, action: GHOSTTY_ACTION_RELEASE) { return }
        super.pressesCancelled(presses, with: event)
    }

    private func forwardPresses(_ presses: Set<UIPress>, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            var keyEvent = ghostty_input_key_s(
                action: action,
                mods: mods(from: key.modifierFlags),
                consumed_mods: GHOSTTY_MODS_NONE,
                keycode: UInt32(key.keyCode.rawValue),
                text: nil,
                unshifted_codepoint: key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0,
                composing: false
            )
            let text = key.characters
            if text.isEmpty {
                ghostty_surface_key(surface, keyEvent)
            } else {
                text.utf8CString.withUnsafeBufferPointer { buf in
                    keyEvent.text = buf.baseAddress
                    ghostty_surface_key(surface, keyEvent)
                }
            }
        }
        return handled
    }

    private func mods(from flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.alphaShift) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }
}

/// Weak relay between CADisplayLink and the surface, so the link doesn't retain
/// the view (which would leak it and keep it drawing after teardown).
private final class DisplayLinkProxy {
    weak var surface: GhosttyTerminalSurface?
    init(_ surface: GhosttyTerminalSurface) { self.surface = surface }
    @objc func tick() { surface?.renderTick() }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
#endif
