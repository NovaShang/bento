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
    /// Click anywhere in the surface → make this the active pane. Host wires to
    /// `viewModel.selectPane`. (The surface consumes mouseDown for selection, so
    /// the container's click handler no longer fires — this restores it.)
    public var onSelect: (() -> Void)?
    /// Right-click-and-hold → voice input. `onVoiceStart` fires (with the press
    /// point in SCREEN coords) once the hold passes the threshold; `onVoiceDrag`
    /// streams the cursor (screen coords) for the compass; `onVoiceEnd` fires on
    /// release. Host wires these to its `MacVoiceController`. When unset, the hold
    /// falls back to the normal right-click (context menu / mouse-report forward).
    public var onVoiceStart: ((NSPoint) -> Void)?
    public var onVoiceDrag: ((NSPoint) -> Void)?
    public var onVoiceEnd: (() -> Void)?
    public private(set) var currentSize: TerminalSurfaceSize?

    private var surface: ghostty_surface_t?
    private var theme: TerminalTheme
    private var renderLink: CVDisplayLink?

    /// `ghostty_surface_draw` synchronously waits for the GPU
    /// (`MTLCommandBuffer.waitUntilCompleted`). When a frame stalls (Space
    /// switch, display sleep, occluded-but-visible transitions, GPU contention)
    /// that wait can last many seconds — so it must NOT run on the main thread,
    /// or the whole app freezes (keys, voice, everything). The display link
    /// enqueues the draw here instead; a stalled frame blocks only this queue,
    /// the UI stays live. `surfaceLock` guards the `surface` pointer across the
    /// render queue (draw + free) and the main thread (create + teardown).
    private let renderQueue = DispatchQueue(label: "com.novashang.bento.render", qos: .userInteractive)
    /// Output parsing (`ghostty_surface_process_output`) runs here, SEPARATE from
    /// `renderQueue`, so a slow parse (ghostty's periodic `PageList.grow` bzero)
    /// doesn't make draws queue up behind it — they interleave instead, keeping
    /// the screen updating under heavy output. ghostty's own terminal lock
    /// serializes the parse against the draw internally. The surface free is
    /// chained through BOTH queues (`enqueueSurfaceFree`) so it can never run
    /// while a parse or a draw is still touching the surface.
    private let ioQueue = DispatchQueue(label: "com.novashang.bento.io", qos: .userInteractive)
    private let surfaceLock = NSLock()
    /// Coalesce display-link ticks: never queue a second draw while one is still
    /// in flight (a stalled frame would otherwise pile up thousands of draws).
    private var renderInFlight = false
    /// Dirty flag: the display link only draws when something changed, instead of
    /// an unconditional 60fps redraw of every surface (which kept the GPU and this
    /// queue busy all day on an idle menubar app — battery drain). Set true by any
    /// dirty source (ghostty's RENDER action, output, resize, focus) and consumed
    /// when a draw is scheduled. Starts true so the first frames draw (which also
    /// poll ghostty's grid size to start the pty — see reportSizeIfNeeded).
    /// Guarded by `surfaceLock` since `setNeedsDraw` is called from any thread.
    private var needsDraw = true
    /// Timestamp of the last scheduled draw. Drives a low idle redraw rate so the
    /// cursor keeps blinking (the prebuilt libghostty drives blink internally and
    /// never emits a RENDER action) and any un-marked local change still recovers.
    /// Touched only under `surfaceLock`.
    private var lastDrawNs: UInt64 = 0
    private static let idleRedrawIntervalNs: UInt64 = 250_000_000   // 250ms ≈ 4fps
    /// Once ghostty's cell grid first reports a non-zero size, stop polling it from
    /// every render frame (see `renderTick`): later size changes arrive through
    /// `set_size` (window resize / font change), which calls `reportSizeIfNeeded`
    /// directly. Without this every drawn frame of every pane posts a size-poll to
    /// the main thread — hundreds/sec across many live panes. Guarded by `surfaceLock`.
    private var gridSettled = false
    private var pendingBytes: [Data] = []
    private var lastAppliedFontSize: Float = 0

    // IME state. `markedText` holds the in-flight composition (e.g. pinyin
    // before a candidate is chosen); the key event currently being routed
    // through the input context is stashed so `doCommandBySelector` can encode
    // special keys (Enter/Tab/arrows) via the engine.
    private var markedText = NSMutableAttributedString()
    private var keyEventForIME: NSEvent?
    private var isTornDown = false

    // Scroll-review-compose: local draft capture while scrolled into history.
    // See docs/scroll-review-compose.md and ScrollReviewCompose.swift.
    let compose = ScrollReviewCompose()
    private var composeBar: ComposeBarView?

    // Engine-requested mouse cursor shape (I-beam over text, pointer over links,
    // resize over splits) and hide-on-type visibility.
    private var mouseCursor: NSCursor = .iBeam
    private var mouseHidden = false

    public init(theme: TerminalTheme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        // ghostty attaches and manages its own Metal layer on the NSView (via
        // the nsview handle in the surface config). We must NOT override
        // makeBackingLayer / supply our own CAMetalLayer, or ghostty's layer
        // never renders. Just enable layer-backing.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupCompose()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let renderLink { CVDisplayLinkStop(renderLink) }
        // Free serialized behind any in-flight draw (teardown normally already
        // ran; this is the fallback). Captures only the C pointer, not self.
        surfaceLock.lock(); let s = surface; surface = nil; surfaceLock.unlock()
        if let s { enqueueSurfaceFree(s) }
    }

    /// Explicitly release the ghostty surface + CVDisplayLink, on the main
    /// thread, BEFORE the view/window is deallocated. Relying on `deinit` races
    /// with the display-link render callback and the window-close CoreAnimation
    /// transaction (which committed against the half-freed Metal layer and
    /// crashed — EXC_BAD_ACCESS in -[_NSWindowTransformAnimation dealloc]).
    /// Stopping the link first guarantees no further `ghostty_surface_draw`
    /// touches the layer while AppKit tears the window down. Idempotent.
    public func teardown() {
        guard !isTornDown else { return }
        pendingReviewEntry?.cancel()
        pendingReviewEntry = nil
        rightHoldTimer?.invalidate()
        rightHoldTimer = nil
        if mouseHidden { NSCursor.unhide(); mouseHidden = false }
        renderObservers.forEach { NotificationCenter.default.removeObserver($0) }
        renderObservers.removeAll()
        if let link = renderLink {
            // Stops scheduling new ticks. (The callback only enqueues onto
            // renderQueue, so this no longer waits for an in-flight draw.)
            CVDisplayLinkStop(link)
            renderLink = nil
        }
        // Detach the surface pointer under the lock so an in-flight parse/draw
        // sees `isTornDown` / nil. Free it behind both queues (enqueueSurfaceFree):
        // serialized after any running parse or draw, so it can never free a
        // surface mid-use — even if a draw is stuck for seconds (the free just
        // waits its turn off-main; the main thread / window close is never blocked).
        surfaceLock.lock()
        isTornDown = true
        let s = surface
        surface = nil
        surfaceLock.unlock()
        if let s {
            if GhosttyRuntime.shared.pasteSurface == s { GhosttyRuntime.shared.pasteSurface = nil }
            enqueueSurfaceFree(s)
        }
        currentSize = nil
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }
    // Allow a click to both focus this pane AND register as the first mouse event
    // (so the click that focuses a pane also reaches a mouse-reporting TUI).
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Keep ghostty's focus in sync with first-responder status. ghostty gates
    // key input AND mouse reporting on the surface being focused; without this
    // the active pane's surface stays unfocused in the engine after a pane/tab
    // switch, so mouse events (and keys) are dropped. (iOS does the same.)
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

    // MARK: - Lifecycle

    private var renderObservers: [NSObjectProtocol] = []

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderObservers.forEach { NotificationCenter.default.removeObserver($0) }
        renderObservers.removeAll()
        guard let window else { stopRenderLink(); return }
        createSurfaceIfNeeded()
        // Start/stop the render loop with the window's visibility (occlusion /
        // miniaturize) so we never spin the GPU-blocking draw while off screen.
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            renderObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.updateRenderActive()
            })
        }
        updateRenderActive()
    }

    // Fires when the window moves to a display with a different backing scale
    // factor (e.g. a 2× Retina panel ↔ a 1× external monitor). Push the new
    // content scale + drawable size to ghostty so glyphs keep the same physical
    // size; otherwise the OS up/down-scales a stale-resolution drawable and the
    // text balloons (1×→2×) or shrinks (2×→1×) by the scale ratio.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceSize()
    }

    public override func layout() {
        super.layout()
        createSurfaceIfNeeded()
        updateSurfaceSize()
        layoutComposeBar()
    }

    private var currentScale: CGFloat {
        let s = window?.backingScaleFactor ?? 2.0
        return s > 0 ? s : 2.0
    }

    private func createSurfaceIfNeeded() {
        guard !isTornDown,
              surface == nil,
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
        // Publish the surface and claim any buffered bytes atomically — a feed
        // racing on renderQueue either appended to pendingBytes (captured here)
        // or will see the live surface and process directly.
        surfaceLock.lock()
        surface = created
        let queued = pendingBytes
        pendingBytes.removeAll()
        surfaceLock.unlock()
        lastAppliedFontSize = Float(theme.fontSize)

        updateSurfaceSize()
        ghostty_surface_set_focus(created, true)
        ghostty_surface_refresh(created)
        ghostty_surface_draw(created)
        updateRenderActive()

        for chunk in queued { feed(chunk) }
    }

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = currentScale
        let w = bounds.width * scale
        let h = bounds.height * scale
        // Clamp to a sane drawable range. A multi-client tmux resize (e.g. the
        // system Terminal attached to the same session and dragging) can briefly
        // hand us a degenerate or huge size; an out-of-range Metal drawable
        // triggers a texture-validation abort / GPU stall. Metal's max texture
        // dimension is 16384 on Apple GPUs.
        guard w >= 1, h >= 1, w <= 16384, h <= 16384 else { return }
        // ghostty makes this a LAYER-HOSTING view (it assigns its own CAMetalLayer
        // via the nsview handle) and sets the layer's contentsScale ONCE at
        // creation from cfg.scale_factor. AppKit does NOT auto-maintain
        // contentsScale for a hosted layer, so when the window is dragged to a
        // display with a different backing scale (2× Retina ↔ 1× external),
        // set_content_scale below fixes ghostty's render density but the layer
        // still COMPOSITES the drawable at the stale scale — glyphs come out
        // wrong by exactly the ratio (and a window resize doesn't fix it, since
        // that only changes bounds). Sync it here, matching the iOS path's
        // synchronizeGhosttyLayerGeometry.
        if let layer, layer.contentsScale != scale {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            CATransaction.commit()
        }
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, UInt32(w), UInt32(h))
        ghostty_surface_refresh(surface)
        setNeedsDraw()
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
        guard size.columns > 0, size.rows > 0 else {
            // Grid not computed yet (ghostty needs a few frames after creation).
            // Keep requesting draws until it settles, so onSizeChanged fires and
            // the pty starts — otherwise the dirty gate would stop drawing first.
            setNeedsDraw()
            return
        }
        // Grid has settled — stop the per-frame size poll from renderTick.
        surfaceLock.lock(); gridSettled = true; surfaceLock.unlock()
        guard size != currentSize else { return }
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
        if renderLink == nil {
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else { return }
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userdata in
                guard let userdata else { return kCVReturnSuccess }
                let view = Unmanaged<GhosttyTerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
                view.enqueueRenderTick()
                return kCVReturnSuccess
            }, ctx)
            renderLink = link
        }
        if let renderLink, !CVDisplayLinkIsRunning(renderLink) { CVDisplayLinkStart(renderLink) }
    }

    private func stopRenderLink() {
        if let renderLink, CVDisplayLinkIsRunning(renderLink) { CVDisplayLinkStop(renderLink) }
    }

    /// Run the render loop only while the surface is actually on screen. ghostty's
    /// draw blocks the main thread on `waitUntilCompleted`; when the window is
    /// occluded / miniaturized, Metal's `nextDrawable` stalls, so an unpaused
    /// display link hangs the app (multi-second beachballs). We also tell ghostty
    /// it's occluded so it skips its own rendering.
    private func updateRenderActive() {
        guard let surface, !isTornDown else { return }
        let visible = isSurfaceVisible
        ghostty_surface_set_occlusion(surface, visible)
        if visible { startRenderLink() } else { stopRenderLink() }
    }

    private var isSurfaceVisible: Bool {
        guard !isTornDown, let window, !isHiddenOrHasHiddenAncestor else { return false }
        if window.isMiniaturized { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Called on the CVDisplayLink thread. Hand the draw to the render queue,
    /// coalescing so a stalled frame can't pile up a backlog of ticks.
    fileprivate func enqueueRenderTick() {
        let now = DispatchTime.now().uptimeNanoseconds
        surfaceLock.lock()
        if renderInFlight || isTornDown { surfaceLock.unlock(); return }
        // Draw when marked dirty (output/interaction → snappy, full frame rate);
        // otherwise only at a low idle rate (cursor blink + a backstop for any
        // un-marked change). This is what turns the always-on 60fps redraw of
        // every surface into a dirty-driven one — the idle GPU/CPU cost drops
        // from 60fps/surface to ~4fps/surface.
        let idleDue = (now &- lastDrawNs) >= Self.idleRedrawIntervalNs
        if !needsDraw && !idleDue { surfaceLock.unlock(); return }
        needsDraw = false
        renderInFlight = true
        lastDrawNs = now
        surfaceLock.unlock()
        renderQueue.async { [weak self] in self?.renderTick() }
    }

    /// Mark the surface dirty so the next display-link tick draws it. Lock-guarded
    /// and callable from any thread — ghostty's RENDER action can arrive off the
    /// main thread, and output (`feed`) runs on `ioQueue`.
    func setNeedsDraw() {
        surfaceLock.lock(); needsDraw = true; surfaceLock.unlock()
    }

    /// Runs on `renderQueue` (NOT main). The synchronous GPU wait inside
    /// `ghostty_surface_draw` therefore blocks only this queue if a frame stalls.
    private func renderTick() {
        surfaceLock.lock()
        let s = surface
        let torn = isTornDown
        let settled = gridSettled
        surfaceLock.unlock()
        defer {
            surfaceLock.lock(); renderInFlight = false; surfaceLock.unlock()
        }
        guard !torn, let s else { return }
        // `s` stays valid for this draw: the free is chained onto renderQueue
        // (via enqueueSurfaceFree), serialized behind this running block.
        ghostty_surface_draw(s)
        // ghostty computes its cell grid a few frames after creation; poll it from
        // the draw loop ONLY until it first settles (then `gridSettled` gates this
        // off). After that, size changes come through set_size, which calls
        // reportSizeIfNeeded directly — so we don't post a main-thread size-poll on
        // every frame of every pane (hundreds/sec across many live panes).
        if !settled {
            DispatchQueue.main.async { [weak self] in self?.reportSizeIfNeeded() }
        }
    }

    // MARK: - TerminalSurface

    /// Process terminal output OFF the main thread, on `ioQueue`.
    ///
    /// `ghostty_surface_process_output` parses the byte stream into ghostty's
    /// screen model; under sustained output it periodically grows the scrollback
    /// (`PageList.grow`), whose large `bzero` was blocking the MAIN thread for
    /// ~1s — freezing keystrokes and stalling further output delivery (the
    /// "freeze then burst of many lines" + input lag). ghostty's processing is
    /// internally locked and safe to run off the UI thread (its own apprt does
    /// IO on a dedicated thread). Running on `ioQueue` (separate from the draw's
    /// `renderQueue`) lets draws interleave with parsing instead of queuing
    /// behind it; `enqueueSurfaceFree` chains the free through both queues so it
    /// can never race an in-flight parse or draw (no use-after-free).
    public func feed(_ data: Data) {
        ioQueue.async { [weak self] in self?.processFeed(data) }
    }

    private func processFeed(_ data: Data) {
        // Read the surface pointer under the lock. If it's gone (torn down) bail;
        // if it's not created yet, buffer. `s` stays valid for the rest of this
        // method because the free is chained behind both queues (see
        // `enqueueSurfaceFree`), so it can't run until this parse returns.
        surfaceLock.lock()
        if isTornDown { surfaceLock.unlock(); return }
        guard let s = surface else {
            if !data.isEmpty { pendingBytes.append(data) }
            surfaceLock.unlock()
            return
        }
        surfaceLock.unlock()

        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: CChar.self).baseAddress else { return }
            ghostty_surface_process_output(s, ptr, UInt(data.count))
        }
        ghostty_surface_refresh(s)
        setNeedsDraw()
    }

    /// Free a surface only after BOTH the parse queue and the render queue have
    /// drained their current work. The caller must have already detached the
    /// pointer (`surface = nil` under `surfaceLock`) so new parse/draw calls bail
    /// without using it. Chaining `ioQueue → renderQueue` guarantees any
    /// in-flight `process_output` (ioQueue) and `draw` (renderQueue) — which each
    /// captured the raw pointer before the detach — have finished before the
    /// free runs. Captures only the queue + pointer, never `self` (safe from
    /// `deinit`).
    private func enqueueSurfaceFree(_ s: ghostty_surface_t) {
        let rq = renderQueue
        ioQueue.async { rq.async { ghostty_surface_free(s) } }
    }

    public func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        if surface != nil, abs(theme.fontSize - Double(lastAppliedFontSize)) > 0.01 {
            // Free the old surface only after any in-flight parse/draw finish
            // (see enqueueSurfaceFree) — never out from under either queue.
            surfaceLock.lock()
            let old = surface
            surface = nil
            surfaceLock.unlock()
            if let old { enqueueSurfaceFree(old) }
            currentSize = nil
            // New surface → re-poll the grid from the draw loop until it settles.
            surfaceLock.lock(); gridSettled = false; surfaceLock.unlock()
            createSurfaceIfNeeded()
        }
    }

    public func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
        setNeedsDraw()
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
        // Scroll-review-compose: while reviewing history, the bar owns navigation
        // and editing keys (returns true = consumed). Printable text still flows
        // through the IME path below and branches into the draft in insertText.
        if compose.isReviewing, handleReviewKeyDown(event) { return }

        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            switch key {
            case "d":
                // ⌘D / ⌘⇧D → split the active pane (iTerm2-style).
                onSplit?(!event.modifierFlags.contains(.shift))
                return
            case "c" where hasSelection:
                // ⌘C → copy the selection to the pasteboard (only when there IS
                // a selection; otherwise fall through so ⌘C can be a no-op
                // rather than interrupting).
                copySelection()
                return
            case "v":
                // While composing, ⌘V pastes into the draft, not the terminal.
                if compose.isReviewing {
                    if let s = TerminalClipboard.read() { compose.insertText(s) }
                } else {
                    pasteFromClipboard()
                }
                return
            case "a":
                _ = selectAll()
                return
            default:
                // Other ⌘ chords aren't text input — encode directly (bypass the
                // IME so we don't insert "v" etc.). They reach the engine and snap
                // to bottom, so bail the draft first to avoid an auto-commit.
                if compose.isReviewing { compose.cancelForPassthrough() }
                sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
                return
            }
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
        // While reviewing, draft keys never reached the engine — don't leak a
        // stray key-up to it either.
        if compose.isReviewing { return }
        // Don't emit key-up while composing — the IME owns the sequence.
        guard markedText.length == 0 else { return }
        sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
    }

    // MARK: - Scroll

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }

        // Mouse-reporting pane → forward wheel as button 64 (up) / 65 (down).
        // One report per wheel event; coalesced trackpad deltas are fine here.
        if mouseReporting.any, abs(event.scrollingDeltaY) > 0.0 {
            forwardMouse(event, button: event.scrollingDeltaY > 0 ? 64 : 65, press: true)
            return
        }

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
        setNeedsDraw()
    }

    public override func mouseMoved(with event: NSEvent) {
        updateMousePosition(event)
    }

    // A tracking area is required for `mouseMoved` to fire at all — without it,
    // mouse-motion reporting (xterm modes 1002/1003) and hover never reach the
    // app. Scoped to the key window + visible rect so background panes stay quiet.
    private var trackingArea: NSTrackingArea?
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    private func updateMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let p = pxPoint(event)
        ghostty_surface_mouse_pos(surface, p.x, p.y, modsFromFlags(event.modifierFlags))
    }

    // MARK: - Mouse selection

    /// Mouse position for ghostty in LOGICAL POINTS (not backing pixels).
    /// ghostty applies the surface content scale internally, so passing pixels
    /// double-applies the scale (selection landed at 2× the row on Retina).
    private func pxPoint(_ event: NSEvent) -> (x: Double, y: Double) {
        let loc = convert(event.locationInWindow, from: nil)
        return (Double(loc.x), Double(loc.y))
    }

    // MARK: - Mouse reporting (tmux -CC)

    /// Per-pane mouse-reporting mode, learned from tmux's `mouse_any_flag` /
    /// `mouse_sgr_flag` (the engine can't see the program's mouse-enable through
    /// control mode). When `any` is on, mouse events are ENCODED and forwarded to
    /// the program via `onInput` instead of doing local selection. Set by the host.
    public struct MouseReporting: Equatable {
        public var any: Bool
        public var sgr: Bool
        public init(any: Bool = false, sgr: Bool = false) { self.any = any; self.sgr = sgr }
    }
    public var mouseReporting = MouseReporting()

    /// Cell (col,row), 1-based, for a mouse event — from the cell pixel size.
    private func cellCoord(_ event: NSEvent) -> (col: Int, row: Int) {
        let p = pxPoint(event)
        guard let cs = currentSize, cs.cellWidthPx > 0, cs.cellHeightPx > 0 else { return (1, 1) }
        let scale = Double(currentScale)
        let col = max(1, Int(p.x / (Double(cs.cellWidthPx) / scale)) + 1)
        let row = max(1, Int(p.y / (Double(cs.cellHeightPx) / scale)) + 1)
        return (col, row)
    }

    private func mouseModBits(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.shift) ? 4 : 0)
            + (flags.contains(.option) ? 8 : 0)
            + (flags.contains(.control) ? 16 : 0)
    }

    /// Encode a mouse event and forward it to the program. `button`: 0=left,
    /// 1=middle, 2=right, 64=wheel-up, 65=wheel-down. Returns true if sent.
    @discardableResult
    private func forwardMouse(_ event: NSEvent, button: Int, press: Bool, motion: Bool = false) -> Bool {
        guard mouseReporting.any else { return false }
        let (col, row) = cellCoord(event)
        let mods = mouseModBits(event.modifierFlags)
        if mouseReporting.sgr {
            let b = button + mods + (motion ? 32 : 0)
            onInput?(Data("\u{1b}[<\(b);\(col);\(row)\(press ? "M" : "m")".utf8))
        } else {
            // Legacy X10/normal: ESC [ M  (b+32)(col+32)(row+32). Release = btn 3.
            let base = press ? button : 3
            let b = base + mods + (motion ? 32 : 0)
            let cb = UInt8(clamping: b + 32)
            let cx = UInt8(clamping: min(col, 223) + 32)
            let cy = UInt8(clamping: min(row, 223) + 32)
            onInput?(Data([0x1b, 0x5b, 0x4d, cb, cx, cy]))
        }
        return true
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?()
        guard let surface else { return }
        // Mouse-reporting pane → forward the click to the program (not selection).
        if forwardMouse(event, button: 0, press: true) { return }
        if event.clickCount >= 2 {
            _ = GhosttySel.selectWord(surface, px: pxPoint(event))
        } else {
            GhosttySel.begin(surface, px: pxPoint(event), mods: modsFromFlags(event.modifierFlags))
        }
        setNeedsDraw()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        if forwardMouse(event, button: 0, press: true, motion: true) { return }
        GhosttySel.extend(surface, px: pxPoint(event), mods: modsFromFlags(event.modifierFlags))
        setNeedsDraw()
    }

    public override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        if forwardMouse(event, button: 0, press: false) { return }
        GhosttySel.end(surface, mods: modsFromFlags(event.modifierFlags))
    }

    // Middle button → forward (mouse-report pane, or X11-style middle paste).
    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        if forwardMouse(event, button: 1, press: true) { return }
        guard let surface else { return }
        updateMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE,
                                         modsFromFlags(event.modifierFlags))
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        if forwardMouse(event, button: 1, press: false) { return }
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE,
                                         modsFromFlags(event.modifierFlags))
    }

    // Right button. Press-and-hold (≥ holdThreshold) → voice input (select this
    // pane + start hold-to-talk); a quick right-click → the existing behavior
    // (mouse-report forward, else the Copy/Paste context menu). We defer the
    // quick-click action until release so we can tell a hold from a click.
    private var rightHoldTimer: Timer?
    private var rightVoiceActive = false
    private var rightDownEvent: NSEvent?
    private static let voiceHoldThreshold: TimeInterval = 0.25

    public override func rightMouseDown(with event: NSEvent) {
        rightDownEvent = event
        rightVoiceActive = false
        rightHoldTimer?.invalidate()
        // Arm the hold only if voice is wired for this pane; otherwise the quick
        // right-click on release handles everything. We DON'T forward/menu on
        // down so a hold can supersede the click.
        if onVoiceStart != nil {
            // Add in `.common` modes so it still fires while the mouse button is
            // held (a default-mode timer is starved during event tracking).
            let timer = Timer(timeInterval: Self.voiceHoldThreshold, repeats: false) { [weak self] _ in
                self?.triggerVoiceHold()
            }
            RunLoop.current.add(timer, forMode: .common)
            rightHoldTimer = timer
        }
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if rightVoiceActive { onVoiceDrag?(NSEvent.mouseLocation) }
    }

    public override func rightMouseUp(with event: NSEvent) {
        rightHoldTimer?.invalidate()
        rightHoldTimer = nil
        if rightVoiceActive {
            rightVoiceActive = false
            onVoiceEnd?()
            rightDownEvent = nil
            return
        }
        // Released before the hold threshold → a normal right-click. Forward to a
        // mouse-reporting program (press+release together), else pop our menu.
        if mouseReporting.any {
            _ = forwardMouse(event, button: 2, press: true)
            _ = forwardMouse(event, button: 2, press: false)
        } else if let menu = menu(for: event), let down = rightDownEvent {
            menu.popUp(positioning: nil, at: convert(down.locationInWindow, from: nil), in: self)
        }
        rightDownEvent = nil
    }

    /// Hold passed the threshold → enter voice input for this pane.
    private func triggerVoiceHold() {
        guard !isTornDown, onVoiceStart != nil else { return }
        rightVoiceActive = true
        window?.makeFirstResponder(self)
        onSelect?()
        onVoiceStart?(NSEvent.mouseLocation)
    }

    // MARK: - Selection / clipboard

    var hasSelection: Bool {
        guard let surface else { return false }
        return GhosttySel.hasSelection(surface)
    }

    func selectedText() -> String? {
        guard let surface else { return nil }
        return GhosttySel.selectedText(surface)
    }

    @discardableResult
    func selectAll() -> Bool {
        guard let surface else { return false }
        return GhosttySel.selectAll(surface)
    }

    func copySelection() {
        guard let text = selectedText(), !text.isEmpty else { return }
        TerminalClipboard.write(text)
    }

    func pasteFromClipboard() {
        guard let surface, let text = TerminalClipboard.read(), !text.isEmpty else { return }
        // Route through ghostty's paste action (not raw `ghostty_surface_text`)
        // so it applies bracketed-paste wrapping when the running app enabled it
        // — otherwise newlines in the pasted text fire Enter per line (e.g. you
        // can't paste a multi-line block into Claude Code). The action requests
        // the clipboard via the runtime's `read_clipboard_cb`, which completes on
        // the surface we register here.
        GhosttyRuntime.shared.pasteSurface = surface
        let action = "paste_from_clipboard"
        _ = action.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
        }
    }

    // MARK: - Context menu (right-click)

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: #selector(contextCopy), keyEquivalent: "c")
        copy.isEnabled = hasSelection
        copy.target = self
        menu.addItem(copy)
        let paste = NSMenuItem(title: "Paste", action: #selector(contextPaste), keyEquivalent: "v")
        paste.target = self
        menu.addItem(paste)
        menu.addItem(.separator())
        let all = NSMenuItem(title: "Select All", action: #selector(contextSelectAll), keyEquivalent: "a")
        all.target = self
        menu.addItem(all)
        return menu
    }

    @objc private func contextCopy() { copySelection() }
    @objc private func contextPaste() { pasteFromClipboard() }
    @objc private func contextSelectAll() { _ = selectAll() }

    /// `textOverride` supplies the committed text from the input system (e.g. the
    /// character `insertText` produced) so direct key input is encoded by
    /// ghostty's key pipeline rather than injected as raw text — see `insertText`.
    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e, textOverride: String? = nil) {
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

        if let text = textOverride ?? translatedText(from: event) {
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
        // Dedicated keys (Tab/Return/Keypad-Enter/Escape) carry a control-char
        // `characters` value (\t, \r, \e). Passing that text makes ghostty emit
        // it verbatim and skip its modifier-aware encoding — so Shift+Tab would
        // send a plain Tab instead of backtab (CSI Z). Return nil for these and
        // let ghostty encode from the keycode + mods.
        switch event.keyCode {
        case 48, 36, 76, 53: return nil   // Tab, Return, Keypad Enter, Escape
        default: break
        }
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

        // Scroll-review-compose: committed text (plain typing or an IME candidate)
        // goes into the local draft, not the engine.
        if compose.isReviewing {
            markedText = NSMutableAttributedString()
            compose.insertText(text)
            return
        }

        let wasComposing = markedText.length > 0
        markedText = NSMutableAttributedString()
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
        // Clearing the preedit changes only ghostty's local overlay. The prebuilt
        // libghostty is pull-model and never emits a RENDER action (see
        // GhosttyRuntime), so under the dirty-driven renderer nothing marks this
        // frame — the stale composition would linger until the committed text
        // echoes back (or the 250ms idle tick), i.e. the IME "上屏" lag. Mark
        // dirty so it repaints next frame. (The old unconditional-60fps renderer
        // masked this by redrawing every surface every frame.)
        if wasComposing { setNeedsDraw() }
        guard !text.isEmpty, let surface else { return }

        // Direct key input (not an IME composition commit) must go through the
        // KEY pipeline so ghostty encodes it per the active keyboard protocol
        // (kitty / CSI-u progressive enhancement). `ghostty_surface_text` injects
        // raw text and bypasses that — so TUIs that enabled enhanced key
        // reporting never see the keypress and their q/space/etc. bindings don't
        // fire. (Hardware keys on iOS already go through ghostty_surface_key.)
        if !wasComposing, let event = keyEventForIME {
            sendKeyEvent(event,
                         action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                         textOverride: text)
            return
        }

        // IME commit (e.g. pinyin → 你好) or other multi-char insertion: send as
        // literal text. (Routing this through the key pipeline was tried and makes
        // no difference — ghostty emits the same raw UTF-8 either way, verified by
        // tracing the host bytes.)
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

        // Scroll-review-compose: show the in-flight composition in the bar, not
        // as engine preedit in the terminal.
        if compose.isReviewing {
            compose.setPreedit(text)
            return
        }

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
        setNeedsDraw()
    }

    public func unmarkText() {
        markedText = NSMutableAttributedString()
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
        // Same as insertText: the cleared preedit won't repaint on its own under
        // the dirty-driven renderer, so mark dirty here.
        setNeedsDraw()
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
        // In review, special keys are handled in handleReviewKeyDown before the
        // IME ever sees them; ignore anything that still routes here.
        if compose.isReviewing { return }
        guard let event = keyEventForIME else { return }
        sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    // MARK: - Engine cursor & mouse feedback

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: mouseCursor)
    }

    /// Apply the cursor shape ghostty requests as the pointer moves over text /
    /// links / split handles.
    func handleMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let c = Self.cursor(for: shape)
        guard c != mouseCursor else { return }
        mouseCursor = c
        c.set()
        window?.invalidateCursorRects(for: self)
    }

    private static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE,
             GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE,
             GHOSTTY_MOUSE_SHAPE_S_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: return .operationNotAllowed
        default: return .arrow
        }
    }

    /// Hide the pointer while typing; show it on mouse move. Balanced so the
    /// cursor can't get stuck hidden.
    func handleMouseVisibility(_ visible: Bool) {
        if visible {
            if mouseHidden { NSCursor.unhide(); mouseHidden = false }
        } else if !mouseHidden {
            NSCursor.hide(); mouseHidden = true
        }
    }

    /// URL under the pointer (nil when not over a link) → surface tooltip.
    func handleMouseOverLink(_ url: String?) {
        toolTip = (url?.isEmpty == false) ? url : nil
    }

    // MARK: - Scroll-review-compose

    private func setupCompose() {
        let bar = ComposeBarView(frame: .zero)
        bar.monoFont = composeFont()
        bar.isHidden = true
        addSubview(bar)
        composeBar = bar

        compose.onChange = { [weak self] in self?.updateComposeBar() }
        compose.onInject = { [weak self] text, execute in self?.injectComposed(text, execute: execute) }
        compose.onSnapToBottom = { [weak self] in self?.scrollComposeToBottom() }
    }

    private func composeFont() -> NSFont {
        let size = CGFloat(theme.fontSize > 0 ? theme.fontSize : 13)
        if let fam = theme.fontFamily, let f = NSFont(name: fam, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Debounce timer for arming review mode on a scroll-up. nil unless a
    /// not-at-bottom update is waiting out the settle window.
    private var pendingReviewEntry: DispatchWorkItem?

    /// Called by GhosttyRuntime on every SCROLLBAR action (already on main).
    ///
    /// ghostty emits a transient not-at-bottom frame while it auto-scrolls to
    /// the new bottom on fresh output (the echo of your own typing, or a CJK
    /// preedit refresh): for one frame `offset+len < total` before the pin
    /// catches up. Forwarding that blip straight to the compose machine armed
    /// review mode (`isReviewing`), which routed the next IME commit into the
    /// draft bar instead of the engine — the text then only surfaced on the
    /// following at-bottom update, read as a ~1s "上屏" stutter on ~1/3 of
    /// commits. So debounce the live→review *entry*: only a scroll-up that
    /// persists past a short settle window is a real, user-initiated scroll.
    func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        let atBottom = offset + len >= total
        if atBottom {
            // Any real bottom cancels a pending entry and is reported at once.
            pendingReviewEntry?.cancel()
            pendingReviewEntry = nil
            compose.scrollChanged(atBottom: true)
            return
        }
        // Already reviewing: forward scroll updates immediately so draft/scroll
        // stay responsive. Only the initial entry from `.live` is debounced.
        if compose.isReviewing {
            compose.scrollChanged(atBottom: false)
            return
        }
        guard pendingReviewEntry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReviewEntry = nil
            self.compose.scrollChanged(atBottom: false)
        }
        pendingReviewEntry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    private var composeBarHeight: CGFloat { ceil(composeFont().ascender - composeFont().descender) + 16 }

    private func layoutComposeBar() {
        guard let bar = composeBar else { return }
        let h = composeBarHeight
        // isFlipped == true, so the bottom strip sits at the max-y edge.
        bar.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
    }

    private func updateComposeBar() {
        guard let bar = composeBar else { return }
        switch compose.phase {
        case .live:
            bar.isHidden = true
        case .reviewIdle:
            bar.monoFont = composeFont()
            bar.isHidden = false
            bar.showHint()
        case .reviewDraft:
            bar.monoFont = composeFont()
            bar.isHidden = false
            bar.showDraft(before: compose.before, preedit: compose.preedit, after: compose.after)
        }
        layoutComposeBar()
    }

    /// Keys the bar owns while reviewing. Returns true if fully consumed (no
    /// further handling), false to fall through (control / ⌘ chords).
    private func handleReviewKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        // Control chords (Ctrl-C/D/Z…) go to the engine, which snaps to bottom.
        // Discard the draft first so the snap doesn't auto-commit it.
        if mods.contains(.control) {
            compose.cancelForPassthrough()
            return false
        }
        switch event.keyCode {
        case 53:                      // Escape
            compose.escape(); return true
        case 36, 76:                  // Return, Keypad Enter
            if mods.contains(.shift) { compose.newline() }
            else if mods.contains(.command) { compose.commit(execute: true) }
            else { compose.commit(execute: false) }
            return true
        case 51:                      // Delete (Backspace)
            compose.backspace(); return true
        case 117:                     // Forward Delete
            compose.deleteForward(); return true
        case 123:                     // Left
            compose.moveLeft(); return true
        case 124:                     // Right
            compose.moveRight(); return true
        case 126:                     // Up
            reviewScroll(lines: -1); return true
        case 125:                     // Down
            reviewScroll(lines: 1); return true
        case 116:                     // Page Up
            reviewScroll(lines: -max(1, (currentSize?.rows ?? 10) - 2)); return true
        case 121:                     // Page Down
            reviewScroll(lines: max(1, (currentSize?.rows ?? 10) - 2)); return true
        default:
            return false              // printable / other → ⌘ handling + IME path
        }
    }

    /// Scroll the history view by `lines` (negative = up/older) without touching
    /// the engine key pipeline (so it doesn't snap to bottom).
    private func reviewScroll(lines: Int) {
        guard let surface else { return }
        // Match scrollWheel's sign: positive y scrolls toward older content.
        ghostty_surface_mouse_scroll(surface, 0, Double(-lines), 0)
        ghostty_surface_refresh(surface)
        setNeedsDraw()
    }

    /// Inject a committed draft into the program's real input line via ghostty's
    /// paste pipeline (bracketed-paste wrapping when the app enabled it) without
    /// clobbering the system clipboard. `execute` then sends a CR to run it.
    private func injectComposed(_ text: String, execute: Bool) {
        guard let surface, !text.isEmpty else { return }
        GhosttyRuntime.shared.pendingPasteText = text
        GhosttyRuntime.shared.pasteSurface = surface
        let paste = "paste_from_clipboard"
        _ = paste.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(paste.utf8.count))
        }
        if execute { sendReturn() }
    }

    private func sendReturn() {
        guard let surface else { return }
        let keyEvent = ghostty_input_key_s(
            action: GHOSTTY_ACTION_PRESS,
            mods: GHOSTTY_MODS_NONE,
            consumed_mods: GHOSTTY_MODS_NONE,
            keycode: 36,            // macOS virtual keycode for Return
            text: nil,
            unshifted_codepoint: 0,
            composing: false
        )
        ghostty_surface_key(surface, keyEvent)
    }

    private func scrollComposeToBottom() {
        guard let surface else { return }
        let action = "scroll_to_bottom"
        _ = action.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
        }
        ghostty_surface_refresh(surface)
    }
}
#endif
