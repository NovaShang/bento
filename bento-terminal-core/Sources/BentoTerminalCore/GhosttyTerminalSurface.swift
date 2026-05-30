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
        if window != nil { createSurfaceIfNeeded() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        createSurfaceIfNeeded()
        updateSurfaceSize()
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
        // DEL (0x7f); emitted directly to host for Phase 1. Proper key handling
        // (arrows, ctrl chords) via ghostty_surface_key + UIKey is a later step.
        onInput?(Data([0x7f]))
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
