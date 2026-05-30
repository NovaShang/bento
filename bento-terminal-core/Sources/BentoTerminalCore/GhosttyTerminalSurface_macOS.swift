#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import GhosttyKit

/// libghostty-backed terminal surface for macOS. Same external-backend contract
/// as the iOS surface (`TerminalSurface`): host feeds remote/pty bytes via
/// `feed`, the engine emits encoded keystrokes back through the runtime's
/// `write_to_host` callback. The view is a CAMetalLayer that libghostty renders
/// into. Mac code (BentoMenubar terminal window) uses it through the protocol,
/// identically to iOS.
public final class GhosttyTerminalSurface: NSView, TerminalSurface {

    public var onInput: ((Data) -> Void)?
    public var onSizeChanged: ((TerminalSurfaceSize) -> Void)?
    public var onTitleChanged: ((String) -> Void)?
    public private(set) var currentSize: TerminalSurfaceSize?

    private var surface: ghostty_surface_t?
    private var theme: TerminalTheme
    private var renderLink: CVDisplayLink?
    private var pendingBytes: [Data] = []
    private var lastAppliedFontSize: Float = 0

    public init(theme: TerminalTheme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        // ghostty attaches and manages its own Metal layer on the NSView (via
        // the nsview handle in the surface config). We must NOT override
        // makeBackingLayer / supply our own CAMetalLayer, or ghostty's layer
        // never renders. Just enable layer-backing.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let renderLink { CVDisplayLinkStop(renderLink) }
        if let surface { ghostty_surface_free(surface) }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    // MARK: - Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { createSurfaceIfNeeded() }
    }

    public override func layout() {
        super.layout()
        createSurfaceIfNeeded()
        updateSurfaceSize()
    }

    private var currentScale: CGFloat {
        let s = window?.backingScaleFactor ?? 2.0
        return s > 0 ? s : 2.0
    }

    private func createSurfaceIfNeeded() {
        guard surface == nil,
              bounds.width > 0, bounds.height > 0,
              let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        cfg.scale_factor = Double(currentScale)
        cfg.font_size = Float(theme.fontSize)
        cfg.wait_after_command = false

        guard let created = ghostty_surface_new(app, &cfg) else { return }
        surface = created
        lastAppliedFontSize = Float(theme.fontSize)

        updateSurfaceSize()
        ghostty_surface_set_focus(created, true)
        ghostty_surface_refresh(created)
        ghostty_surface_draw(created)
        startRenderLink()

        let queued = pendingBytes
        pendingBytes.removeAll()
        for chunk in queued { feed(chunk) }
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
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userdata in
            guard let userdata else { return kCVReturnSuccess }
            let view = Unmanaged<GhosttyTerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { view.renderTick() }
            return kCVReturnSuccess
        }, ctx)
        CVDisplayLinkStart(link)
        renderLink = link
    }

    private func renderTick() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
        // ghostty computes its cell grid a few frames after creation; keep
        // polling until we get a non-zero size so onSizeChanged fires (which
        // starts the pty). reportSizeIfNeeded only emits on actual change.
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
        if surface != nil, abs(theme.fontSize - Double(lastAppliedFontSize)) > 0.01 {
            if let surface { ghostty_surface_free(surface) }
            surface = nil
            currentSize = nil
            createSurfaceIfNeeded()
        }
    }

    public func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    /// Called by GhosttyRuntime when the engine has bytes for the host.
    func handleHostWrite(_ data: Data) {
        onInput?(data)
    }

    // MARK: - Input

    // All key input goes through ghostty_surface_key (NOT ghostty_surface_text),
    // so the engine encodes everything correctly: printable text as text, Enter
    // as CR, arrows/function keys as escape sequences, Ctrl-chords as control
    // bytes. Feeding raw event.characters to ghostty_surface_text (the old
    // approach) echoed special keys as private-use glyphs and never sent CR.

    public override func keyDown(with event: NSEvent) {
        sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    public override func keyUp(with event: NSEvent) {
        sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
    }

    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }

        var keyEvent = ghostty_input_key_s(
            action: action,
            mods: modsFromFlags(event.modifierFlags),
            consumed_mods: consumedMods(from: event, surface: surface),
            keycode: UInt32(event.keyCode),
            text: nil,
            unshifted_codepoint: unshiftedCodepoint(from: event),
            composing: false
        )

        if let text = translatedText(from: event) {
            text.withCString { ptr in
                keyEvent.text = ptr
                ghostty_surface_key(surface, keyEvent)
            }
        } else {
            ghostty_surface_key(surface, keyEvent)
        }
    }

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    /// Ghostty-translated mods (option-as-alt etc.), minus ctrl/super so the
    /// engine knows which mods contributed to generated text.
    private func consumedMods(from event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_mods_e {
        let translated = ghostty_surface_key_translation_mods(surface, modsFromFlags(event.modifierFlags))
        var raw = translated.rawValue
        raw &= ~GHOSTTY_MODS_CTRL.rawValue
        raw &= ~GHOSTTY_MODS_SUPER.rawValue
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    /// The text payload for the key event, or nil to let ghostty derive it from
    /// keycode. Control chars and private-use function keys (arrows etc.) return
    /// nil/stripped so the engine encodes them itself.
    private func translatedText(from event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 {
                // Control character — let ghostty encode it; pass the
                // unmodified-by-control text so it knows the base key.
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                // Private-use range = arrows / function keys; encode via keycode.
                return nil
            }
        }
        return chars
    }
}
#endif
