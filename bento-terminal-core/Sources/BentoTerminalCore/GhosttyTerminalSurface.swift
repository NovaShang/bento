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
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: - Lifecycle / surface creation

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            createSurfaceIfNeeded()
            synchronizeGhosttyLayerGeometry()
            updateSurfaceSize()
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
        guard surface == nil,
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

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = currentScale
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
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
        guard renderLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(renderTick))
        link.add(to: .main, forMode: .common)
        renderLink = link
    }

    @objc private func renderTick() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
        // ghostty computes its cell grid a few frames after creation; poll so
        // onSizeChanged fires once it's non-zero (drives tmux/PTY resize).
        reportSizeIfNeeded()
    }

    // MARK: - TerminalSurface

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
    public var keyboardType: UIKeyboardType = .asciiCapable
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no

    public func insertText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        // Route through ghostty so it encodes per terminal mode; the encoded
        // bytes come back via write_to_host -> onInput.
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                ghostty_surface_text(surface, ptr, UInt(buf.count))
            }
        }
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
