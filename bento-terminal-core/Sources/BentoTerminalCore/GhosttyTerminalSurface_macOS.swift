#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import GhosttyKit

/// libghostty-backed terminal surface for macOS. Same external-backend contract
/// as the iOS surface (`TerminalSurface`): host feeds remote/pty bytes via
/// `feed`, the engine emits encoded keystrokes back through the runtime's
/// `write_to_host` callback. The view is a CAMetalLayer that libghostty renders
/// into. Mac code (BentoMenubar terminal window) uses it through the protocol,
/// identically to iOS.
public final class GhosttyTerminalSurface: NSView, TerminalSurface, NSTextInputClient {

    public var onInput: ((Data) -> Void)?
    public var onSizeChanged: ((TerminalSurfaceSize) -> Void)?
    public var onTitleChanged: ((String) -> Void)?
    /// Split request (⌘D = side-by-side, ⌘⇧D = stacked). Host wires to the VM.
    public var onSplit: ((_ horizontal: Bool) -> Void)?
    public private(set) var currentSize: TerminalSurfaceSize?

    private var surface: ghostty_surface_t?
    private var theme: TerminalTheme
    private var renderLink: CVDisplayLink?
    private var pendingBytes: [Data] = []
    private var lastAppliedFontSize: Float = 0

    // IME state. `markedText` holds the in-flight composition (e.g. pinyin
    // before a candidate is chosen); the key event currently being routed
    // through the input context is stashed so `doCommandBySelector` can encode
    // special keys (Enter/Tab/arrows) via the engine.
    private var markedText = NSMutableAttributedString()
    private var keyEventForIME: NSEvent?

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

    private var sizeDebounce: DispatchWorkItem?

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
        // Debounce the PTY-resize callback. A continuous window drag fires many
        // size changes; coalescing to one resize ~60ms after it settles means
        // the shell gets a single SIGWINCH and the TUI redraws once, instead of
        // garbling through a burst of mid-drag resizes. Rendering is unaffected
        // — ghostty already has the live pixel size via set_size/draw.
        sizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onSizeChanged?(size) }
        sizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
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
        // ⌘D / ⌘⇧D → split the active pane (iTerm2-style), handled by the host
        // rather than forwarded to the shell.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "d" {
            onSplit?(!event.modifierFlags.contains(.shift))
            return
        }

        // ⌘ chords aren't text input — encode directly (bypass the IME so we
        // don't insert "v" for ⌘V etc.).
        if event.modifierFlags.contains(.command) {
            sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
            return
        }

        // Route through the macOS input system so IME composition (Chinese /
        // Japanese / dead keys) works. The input context calls back into our
        // NSTextInputClient conformance: `insertText` for committed text,
        // `setMarkedText` for the in-flight composition, `doCommandBySelector`
        // for special keys. If the context doesn't consume the event we encode
        // it ourselves via the engine.
        keyEventForIME = event
        defer { keyEventForIME = nil }
        if inputContext?.handleEvent(event) != true {
            sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        }
    }

    public override func keyUp(with event: NSEvent) {
        // Don't emit key-up while composing — the IME owns the sequence.
        guard markedText.length == 0 else { return }
        sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
    }

    // MARK: - Scroll

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }

        // ghostty applies scroll at the tracked mouse position, so make sure it
        // knows the cursor is inside this surface first.
        updateMousePosition(event)

        // Pack ghostty's scroll mods: bit 0 = high-precision (trackpad),
        // bits 1-3 = momentum phase (see src/input/mouse.zig).
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods |= 1 }
        let momentum: ghostty_input_mouse_momentum_e
        switch event.momentumPhase {
        case .began:      momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed:    momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended:      momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled:  momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin:   momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default:          momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        mods |= Int32(momentum.rawValue) << 1

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            // Mouse wheel: deltas are in lines — scale so each notch moves a few rows.
            x *= 3
            y *= 3
        }
        ghostty_surface_mouse_scroll(surface, x, y, mods)
        ghostty_surface_refresh(surface)
    }

    public override func mouseMoved(with event: NSEvent) {
        updateMousePosition(event)
    }

    private func updateMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let scale = currentScale
        ghostty_surface_mouse_pos(surface, Double(loc.x) * scale, Double(loc.y) * scale, GHOSTTY_MODS_NONE)
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

    // MARK: - NSTextInputClient (IME)

    /// Committed text from the input system (plain typing, or the chosen IME
    /// candidate). Feed it to the engine as literal text and clear any preedit.
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString()
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
        guard !text.isEmpty, let surface else { return }
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
                ghostty_surface_text(surface, p, UInt(buf.count))
            }
        }
    }

    /// In-flight composition (e.g. pinyin before a candidate is picked). Show it
    /// as ghostty preedit; nothing is sent to the shell until commit.
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString(string: text)
        guard let surface else { return }
        if text.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
        } else {
            let utf8 = Array(text.utf8)
            utf8.withUnsafeBufferPointer { buf in
                buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
                    ghostty_surface_preedit(surface, p, UInt(buf.count))
                }
            }
        }
    }

    public func unmarkText() {
        markedText = NSMutableAttributedString()
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }

    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length)
                              : NSRange(location: NSNotFound, length: 0)
    }

    public func attributedSubstring(forProposedRange range: NSRange,
                                    actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the IME candidate window should anchor. We don't track the exact
    /// cell cursor here, so anchor near the bottom-left of the surface — good
    /// enough that the candidate list is visible and near the typing area.
    public func firstRect(forCharacterRange range: NSRange,
                          actualRange: NSRangePointer?) -> NSRect {
        let local = NSRect(x: 4, y: bounds.height - 24, width: 1, height: 20)
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    /// Special keys routed by the input system (Enter/Tab/Backspace/arrows/Esc).
    /// Encode the stashed key event via the engine; the engine emits the right
    /// escape sequence / control byte.
    public override func doCommand(by selector: Selector) {
        guard let event = keyEventForIME else { return }
        sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }
}
#endif
