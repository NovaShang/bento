#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// ACP chat pane surface for macOS: renders ONE agent conversation
/// (streaming markdown, tool cards, diffs, plan, permission prompts,
/// composer) inside the tiled pane host.
///
/// The voice gesture: right-click-and-hold (≥0.25 s) anywhere in the pane
/// starts hold-to-talk (prewarm on button-down, compass drag, end on
/// release); a quick right-click pops a minimal context menu. Because the
/// SwiftUI hosting view consumes AppKit mouse events before this container
/// sees them, both the pane-select click and the voice gesture are observed
/// through a local NSEvent monitor scoped to this view's bounds — left
/// clicks pass through untouched so normal SwiftUI interaction keeps working.
public final class AgentChatSurface: NSView {

    // MARK: - Host-facing callbacks

    /// Click anywhere in the surface → make this the active pane.
    public var onSelect: (() -> Void)?
    /// Right-click-and-hold → voice input: prewarm on button-down,
    /// `onVoiceStart` (with the press point in SCREEN coords) once the hold
    /// passes the threshold, `onVoiceDrag` streams the cursor (screen
    /// coords), `onVoiceEnd` on release. When unset, right-clicks pass
    /// through to the SwiftUI content.
    public var onVoiceStart: ((NSPoint) -> Void)?
    public var onVoiceDrag: ((NSPoint) -> Void)?
    public var onVoiceEnd: (() -> Void)?
    public var onVoicePrewarm: (() -> Void)?

    /// When set by the host, file paths in tool cards / diffs open in the
    /// shared preview dock.
    public var pathPreviewContext: PathPreviewContext?
    /// The session's working directory.
    public var reportedPwd: String? { chatModel.session?.cwd }
    /// The runtime this surface is currently showing — the host compares it
    /// against the pane's live runtime to re-`attach` after a reset (new
    /// conversation) swaps the pane's agent under a surface that already exists.
    public var boundSession: AgentSessionViewModel? { chatModel.session }
    /// Compact ASR biasing context for this pane (see
    /// `AgentSessionViewModel.voiceContext`). Feeds the Qwen corpus instead of
    /// the whole scrollback, which swamps recognition on long conversations.
    public func voiceBiasContext() -> String? { chatModel.session?.voiceContext() }

    // MARK: - Internals

    private let chatModel: AgentChatModel
    private var hostingView: NSHostingView<AgentChatSurfaceRoot>?
    private var theme: CanvasTheme?
    private var isTornDown = false
    private var sessionBag = Set<AnyCancellable>()
    private var modelBag = Set<AnyCancellable>()

    public init(session: AgentSessionViewModel?, theme: CanvasTheme? = nil) {
        self.theme = theme
        self.chatModel = AgentChatModel(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true

        let root = AgentChatSurfaceRoot(
            model: chatModel,
            openFile: { [weak self] path, line in
                self?.openFilePreview(path: path, line: line)
            })
        let hosting = NSHostingView(rootView: root)
        // The pane host owns this view's frame; never let SwiftUI intrinsic
        // sizing fight the tiled layout.
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
        applyThemeAppearance()

        // Image drags land HERE (not in the composer's field editor, which
        // would insert the file PATH as text) — see the drag-drop section.
        registerForDraggedTypes(Self.imageDragTypes)

        bindSession(session)

        // Every explicit jump-to-bottom (transcript button, host scroll-to-
        // live) funnels through this token — snap the ledger with it so a
        // reflow replay can't drag the viewport back up.
        chatModel.$scrollToBottomToken
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.transcriptPinned = true
                self.bottomLedgerFraction = 0
                self.snapToLiveBottom()
            }
            .store(in: &modelBag)

        // A programmatic jump up in history (the transcript's prev-message nav)
        // funnels through this token too — unpin the ledger so the keep-bottom
        // tick doesn't drag the reader back to the tail on the next shape change.
        chatModel.$userScrolledUpToken
            .dropFirst()
            .sink { [weak self] _ in
                self?.transcriptPinned = false
            }
            .store(in: &modelBag)

        installDiagSamplerIfNeeded()
        installBlankWatchdog()
    }

    /// Sit the chat on the terminal theme's canvas: same background color as
    /// the old terminal panes (so the whole window — toolbar blur included —
    /// keeps its look), with the hosting hierarchy's appearance pinned
    /// light/dark by the theme's luminance so every system semantic color
    /// resolves legibly against it.
    private func applyThemeAppearance() {
        guard let theme else {
            chatModel.themeBackground = nil
            hostingView?.appearance = nil
            return
        }
        chatModel.themeBackground = theme.background
        let bg = theme.background
        let r = Double((bg >> 16) & 0xFF) / 255
        let g = Double((bg >> 8) & 0xFF) / 255
        let b = Double(bg & 0xFF) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        hostingView?.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
    }

    /// Tell the chat whether its pane is currently shown in Focus mode, so the
    /// transcript + composer can adopt the roomier reading layout. Idempotent —
    /// the pane host pushes this on every re-tile; only a real change re-renders.
    public func setFocusMode(_ on: Bool) {
        if chatModel.isFocusMode != on { chatModel.isFocusMode = on }
    }

    /// Tell the chat whether its pane is the selected one, so the composer can
    /// fold its options strip away on unselected tiles. Idempotent — the pane
    /// host pushes this alongside the active-border update; only a real change
    /// re-renders.
    public func setSelected(_ on: Bool) {
        if chatModel.isSelectedPane != on { chatModel.isSelectedPane = on }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        // teardown() normally already ran; this is the fallback so a surface
        // dropped without teardown can't leak its app-wide event monitor.
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let docFrameObserver { NotificationCenter.default.removeObserver(docFrameObserver) }
        if let clipFrameObserver { NotificationCenter.default.removeObserver(clipFrameObserver) }
        contentInsetObserver?.invalidate()
        rightHoldTimer?.invalidate()
        resizeSettleTimer?.invalidate()
        renderReassertTimer?.invalidate()
        blankWatchdogTimer?.invalidate()
        diagTimer?.invalidate()
    }

    /// Attach (or replace) the session after init — e.g. the pane was created
    /// before the agent finished spawning and showed the starting placeholder.
    public func attach(_ session: AgentSessionViewModel) {
        guard !isTornDown else { return }
        chatModel.session = session
        bindSession(session)
        // The placeholder had no scroll views; the session's content (and
        // its transcript scroll view) builds on the next runloop turns.
        scheduleScrollResolution()
    }

    private func bindSession(_ session: AgentSessionViewModel?) {
        sessionBag.removeAll()
        guard let session else { removeSlashPanel(); return }
        // Drive the floating slash-completion panel: it must react to the
        // draft (open/filter/close), the command list and phase (availability),
        // and the highlighted row (↑/↓ from the composer).
        // Typing path: present the panel SYNCHRONOUSLY from the emitted draft,
        // with NO main-queue hop. Measured: behind a heavy transcript render
        // the hop reached ~1.6 s while the panel work itself was ~0 ms; running
        // in the same turn as the keystroke (using the emitted value, since the
        // property's willSet hasn't landed yet) sidesteps that entirely.
        session.$composerDraft
            .sink { [weak self] draft in self?.updateSlashPanel(draft: draft) }
            .store(in: &sessionBag)
        // Availability / highlighted-row changes aren't latency-critical; a
        // hop is fine (and lets them read the settled draft).
        Publishers.Merge3(
            session.$availableCommands.map { _ in () },
            session.$phase.map { _ in () },
            chatModel.$slashSelection.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.updateSlashPanel(draft: nil) }
        .store(in: &sessionBag)
        updateSlashPanel(draft: nil)
    }

    /// Explicitly release everything host-visible. Idempotent (host calls
    /// this when the pane closes).
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        removeSlashPanel()
        diagTimer?.invalidate()
        diagTimer = nil
        blankWatchdogTimer?.invalidate()
        blankWatchdogTimer = nil
        renderReassertTimer?.invalidate()
        renderReassertTimer = nil
        resizeSettleTimer?.invalidate()
        resizeSettleTimer = nil
        rightHoldTimer?.invalidate()
        rightHoldTimer = nil
        rightDownEvent = nil
        rightVoiceActive = false
        hideDropOverlay()
        removeEventMonitor()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        if let docFrameObserver {
            NotificationCenter.default.removeObserver(docFrameObserver)
            self.docFrameObserver = nil
        }
        if let clipFrameObserver {
            NotificationCenter.default.removeObserver(clipFrameObserver)
            self.clipFrameObserver = nil
        }
        contentInsetObserver?.invalidate()
        contentInsetObserver = nil
        sessionBag.removeAll()
        modelBag.removeAll()
        hostingView?.removeFromSuperview()
        hostingView = nil
        onSelect = nil
        onVoicePrewarm = nil
        onVoiceStart = nil
        onVoiceDrag = nil
        onVoiceEnd = nil
    }

    // MARK: - Responder / focus

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The host's `makeFirstResponder(surface)` should land the caret in the
    /// composer — accept, then forward focus into the SwiftUI text field.
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        requestComposerFocus()
        return ok
    }

    public func setFocus(_ focused: Bool) {
        guard !isTornDown else { return }
        if focused {
            requestComposerFocus()
            // Viewing the session clears its done-unseen badge.
            chatModel.session?.markSeen()
        }
    }

    private func requestComposerFocus() {
        // Deferred so a focus change arriving mid SwiftUI update can't
        // publish during view rendering.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.chatModel.requestComposerFocus()
        }
    }

    /// Adopt the theme's canvas (background + light/dark) — the chat pane
    /// keeps the window's look. See applyThemeAppearance.
    public func applyTheme(_ theme: CanvasTheme) {
        self.theme = theme
        applyThemeAppearance()
    }

    public override func layout() {
        super.layout()
        layoutHostingView()
        resolveScrollViewIfNeeded()
        // The composer field moves as the pane resizes / the field grows a
        // line; keep the floating panel glued to it.
        if let host = slashPanelHost, let contentView = window?.contentView {
            positionSlashPanel(host, in: contentView)
        }
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Dragging the window edge is a stream of width changes coalesced by
        // layoutHostingView(); the OS tells us the drag ended, so reflow now
        // instead of waiting out the settle debounce.
        if frozenContentWidth != nil { settleResize() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installEventMonitorIfNeeded()
            scheduleScrollResolution()
        } else {
            removeEventMonitor()
            removeSlashPanel()
        }
    }

    public override func viewDidHide() {
        super.viewDidHide()
        // Focus/zoom mode hides the other panes in place — their draft panels
        // must not linger in the window.
        removeSlashPanel()
    }

    /// The hosting subtree materializes asynchronously, so a single layout()
    /// pass can run before the scroll views exist — leaving the bottom
    /// anchor unattached until the next pane re-tile (if any). The anchor is
    /// only as good as its attachment: retry briefly after appearing and
    /// after a session attaches.
    private func scheduleScrollResolution(attempt: Int = 0) {
        guard !isTornDown, attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.15)) { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.resolveScrollViewIfNeeded()
            if self.cachedScrollView == nil || self.cachedComposerScrollView == nil {
                self.scheduleScrollResolution(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Event monitor (pane select + voice gesture)

    private var eventMonitor: Any?

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil, !isTornDown else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown, .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                .scrollWheel, .keyDown,
            ]
        ) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.routeMonitoredEvent(event) }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    private func isEventInside(_ event: NSEvent) -> Bool {
        // Hidden surfaces keep their last tiled frame (Focus/zoom solo mode
        // hides the others in place), and coordinate math ignores isHidden —
        // without this guard an off-screen pane's monitor claims the event
        // and select/voice jumps to a pane the user can't even see.
        guard event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        let p = convert(event.locationInWindow, from: nil)
        return bounds.contains(p)
    }

    /// True when the pointer sits over the composer's text field — wheel
    /// events there scroll the field's own capped overflow and must not
    /// drive the transcript. Plain rect check against the resolved editor
    /// scroll view; a hitTest walk here would tax every wheel tick.
    private func isEventOverComposerField(_ event: NSEvent) -> Bool {
        guard let composer = cachedComposerScrollView, composer.window === window
        else { return false }
        return composer.bounds.contains(composer.convert(event.locationInWindow, from: nil))
    }

    private func routeMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        guard !isTornDown, window != nil else { return event }
        switch event.type {
        case .leftMouseDown:
            // Fire pane selection, then let the click through so SwiftUI
            // interaction (buttons, text selection, composer) still works.
            guard isEventInside(event) else { return event }
            onSelect?()
            return event
        case .rightMouseDown:
            // Voice unwired → normal right-click behavior (SwiftUI menus).
            guard isEventInside(event), onVoiceStart != nil else { return event }
            beginRightGesture(event)
            return nil
        case .rightMouseDragged:
            guard rightDownEvent != nil || rightVoiceActive else { return event }
            if rightVoiceActive { onVoiceDrag?(NSEvent.mouseLocation) }
            return nil
        case .rightMouseUp:
            guard rightDownEvent != nil || rightVoiceActive else { return event }
            endRightGesture()
            return nil
        case .scrollWheel:
            // A real wheel/trackpad scroll toward older content unpins the
            // transcript's auto-follow (geometry alone can't tell a user
            // scroll from streaming growth). Event passes through untouched.
            // Any wheel also cancels a pending reflow replay — user intent
            // beats the ledger. A scroll INSIDE the composer's own field is
            // its internal overflow, not transcript intent. The token bump
            // fires only on the pinned→unpinned FLIP: bumping per tick
            // republished the chat model — and re-evaluated the whole
            // transcript — on every wheel movement.
            if isEventInside(event), !isEventOverComposerField(event) {
                reflowSettleUntil = 0
                lastScrollWheelAt = ProcessInfo.processInfo.systemUptime
                if event.scrollingDeltaY > 0 {
                    lastWheelUpAt = ProcessInfo.processInfo.systemUptime
                    // Don't unpin here. A nudge within the tail/composer slack
                    // stays "at the tail" (bar shown). maintainBottomAnchor
                    // commits to history mode — unpin + hide the bar — only once
                    // the reader has actually scrolled up past the threshold.
                }
            }
            return event
        case .keyDown:
            return handlePasteShortcutIfImage(event)
        default:
            return event
        }
    }

    /// ⌘V with an image on the pasteboard → attach it, swallow the event.
    /// This runs BEFORE menu key-equivalent dispatch and the composer's
    /// field editor (which would otherwise win `paste:` and drop the image
    /// on the floor — SwiftUI's onPasteCommand never fires on a focused
    /// TextField). Text-only pastes pass through untouched.
    private func handlePasteShortcutIfImage(_ event: NSEvent) -> NSEvent? {
        guard event.window === window,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "v",
            canAttachImages,
            let responder = window?.firstResponder as? NSView,
            responder.isDescendant(of: self)
        else { return event }
        let images = Self.imageAttachments(on: .general, fallbackLabel: "Pasted image")
        guard !images.isEmpty, let session = chatModel.session else { return event }
        for image in images {
            session.attachImage(data: image.data, label: image.label)
        }
        requestComposerFocus()
        return nil
    }

    // MARK: - Voice gesture (right-click-hold, ported thresholds)

    private var rightHoldTimer: Timer?
    private var rightVoiceActive = false
    private var rightDownEvent: NSEvent?
    private static let voiceHoldThreshold: TimeInterval = 0.25

    private func beginRightGesture(_ event: NSEvent) {
        rightDownEvent = event
        rightVoiceActive = false
        rightHoldTimer?.invalidate()
        // Pre-warm the mic engine NOW (button down) so it's live by the time
        // the hold threshold fires — warm-up overlaps the wait.
        onVoicePrewarm?()
        // `.common` modes so the timer still fires while the button is held.
        let timer = Timer(timeInterval: Self.voiceHoldThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.triggerVoiceHold() }
        }
        RunLoop.current.add(timer, forMode: .common)
        rightHoldTimer = timer
    }

    /// Hold passed the threshold → enter voice input for this pane.
    /// NO makeFirstResponder here (unlike the terminal surface, where the
    /// grab routes keystrokes): our becomeFirstResponder forwards focus back
    /// into the composer, and that round-trip makes NSTextField begin editing
    /// again and SELECT ALL — the next insert then wiped the typed draft.
    /// The composer keeps its focus and caret; voice appends via the binding.
    /// If the composer wasn't focused, onSelect's pane-activation path focuses
    /// it only when first responder isn't already inside this surface.
    private func triggerVoiceHold() {
        guard !isTornDown, onVoiceStart != nil else { return }
        rightVoiceActive = true
        onSelect?()
        onVoiceStart?(NSEvent.mouseLocation)
    }

    private func endRightGesture() {
        rightHoldTimer?.invalidate()
        rightHoldTimer = nil
        if rightVoiceActive {
            rightVoiceActive = false
            onVoiceEnd?()
            rightDownEvent = nil
            return
        }
        // Released before the hold threshold → a quick right-click. Chat's
        // analogue of the terminal's Copy/Paste menu.
        if let down = rightDownEvent {
            showChatContextMenu(at: down)
        }
        rightDownEvent = nil
    }

    private func showChatContextMenu(at downEvent: NSEvent) {
        // A quick right-click over the composer field gets the standard macOS
        // text-editing menu (Cut/Copy/Paste/Select All/Look Up/Services),
        // supplied by the field's own NSTextView — the voice-hold gesture
        // still owns the *hold* everywhere; only this quick-click branch
        // diverges. Focus the field first so the menu's editing commands
        // dispatch to it.
        if isEventOverComposerField(downEvent),
           let textView = cachedComposerScrollView?.documentView as? NSTextView {
            window?.makeFirstResponder(textView)
            if let textMenu = textView.menu(for: downEvent) {
                textMenu.popUp(positioning: nil,
                               at: convert(downEvent.locationInWindow, from: nil), in: self)
                return
            }
        }

        let menu = NSMenu()
        // Copy at three scopes: the message under the cursor → its whole answer
        // (the turn) → the entire conversation. Message/answer need a target, so
        // add them only when an agent message is actually hovered.
        if let hovered = chatModel.session?.hoveredMessage, hovered.role == .agent {
            addChatMenuItem(menu, "Copy Message", #selector(contextCopyMessage))
            addChatMenuItem(menu, "Copy Answer", #selector(contextCopyAnswer))
        }
        addChatMenuItem(menu, "Copy Conversation", #selector(contextCopyConversation))
        menu.addItem(.separator())
        addChatMenuItem(menu, "Paste", #selector(contextPaste))
        menu.popUp(positioning: nil, at: convert(downEvent.locationInWindow, from: nil), in: self)
    }

    private func addChatMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func contextCopyMessage() {
        guard let m = chatModel.session?.hoveredMessage else { return }
        copyTextToPasteboard(m.fullText)
    }

    @objc private func contextCopyAnswer() {
        guard let session = chatModel.session, let m = session.hoveredMessage else { return }
        copyTextToPasteboard(session.answerText(around: m))
    }

    @objc private func contextCopyConversation() {
        guard let session = chatModel.session else { return }
        copyTextToPasteboard(session.conversationMarkdown())
    }

    private func copyTextToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func contextPaste() {
        // Same policy as ⌘V: an image on the clipboard attaches, text inserts.
        if canAttachImages, let session = chatModel.session {
            let images = Self.imageAttachments(on: .general, fallbackLabel: "Pasted image")
            if !images.isEmpty {
                for image in images {
                    session.attachImage(data: image.data, label: image.label)
                }
                requestComposerFocus()
                return
            }
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        chatModel.session?.insertIntoComposer(text)
        requestComposerFocus()
    }

    // MARK: - Image drag & drop

    /// Dropping an image file (or raw image data) attaches it to the
    /// composer. Mechanics: AppKit routes a drag to the DEEPEST registered
    /// view, so a drop directly on the composer's text field would go to its
    /// field editor and insert the file path as text. The moment an image
    /// drag enters this surface we float a full-pane overlay (topmost view →
    /// wins the destination hit-test everywhere, text field included) that
    /// receives the drop. Non-image files are left alone on purpose:
    /// path-insert is the desired way to hand the agent a file reference.

    private static let imageDragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    private var canAttachImages: Bool { chatModel.session?.canAttachImages == true }
    private var dropOverlay: AcpDropTargetOverlay?

    /// Image payloads on a pasteboard: image-file URLs first (Finder drags,
    /// copied files), else raw bitmap data (screenshots, browser images).
    private static func imageAttachments(
        on pasteboard: NSPasteboard, fallbackLabel: String
    ) -> [(data: Data, label: String)] {
        let urlOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: urlOptions)
            as? [URL], !urls.isEmpty {
            return urls.compactMap { url in
                (try? Data(contentsOf: url)).map { (data: $0, label: url.lastPathComponent) }
            }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) {
                return [(data: data, label: fallbackLabel)]
            }
        }
        return []
    }

    private static func hasImagePayload(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [
                .urlReadingFileURLsOnly: true,
                .urlReadingContentsConformToTypes: [UTType.image.identifier],
            ]) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isTornDown, canAttachImages, Self.hasImagePayload(sender.draggingPasteboard)
        else { return [] }
        showDropOverlay()
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        // Once the overlay took over as destination, this exit just means the
        // handoff happened; the overlay hides itself on ITS exit/end.
        if dropOverlay?.isActive != true { hideDropOverlay() }
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        if dropOverlay?.isActive != true { hideDropOverlay() }
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    /// Drop before the overlay ever became destination (drop with no
    /// intervening mouse move) still lands here — same attach path.
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        attachDraggedImages(sender)
    }

    private func showDropOverlay() {
        guard dropOverlay == nil else { return }
        let overlay = AcpDropTargetOverlay(frame: bounds, types: Self.imageDragTypes)
        overlay.autoresizingMask = [.width, .height]
        overlay.onPerform = { [weak self] info in self?.attachDraggedImages(info) ?? false }
        overlay.onFinish = { [weak self] in self?.hideDropOverlay() }
        addSubview(overlay)
        dropOverlay = overlay
    }

    private func hideDropOverlay() {
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
    }

    private func attachDraggedImages(_ sender: NSDraggingInfo) -> Bool {
        defer { hideDropOverlay() }
        guard !isTornDown, let session = chatModel.session else { return false }
        let images = Self.imageAttachments(
            on: sender.draggingPasteboard, fallbackLabel: "Dropped image")
        guard !images.isEmpty else { return false }
        for image in images {
            session.attachImage(data: image.data, label: image.label)
        }
        requestComposerFocus()
        return true
    }

    // MARK: - Scrollback bridge (transcript ↔ scroll-bookmark plumbing)

    private weak var cachedScrollView: NSScrollView?
    private weak var observedDocView: NSView?
    private var scrollObserver: NSObjectProtocol?
    private var docFrameObserver: NSObjectProtocol?
    private var clipFrameObserver: NSObjectProtocol?
    private var contentInsetObserver: NSKeyValueObservation?

    // MARK: Bottom-anchored reading position
    //
    // Scroll ownership is split by ONE intent-driven flag:
    //
    // - PINNED (`transcriptPinned`, the default): the reader rides the live
    //   tail. Any SHAPE change — streaming growth, lazy rows materializing
    //   after a scrollTo overshoot, the composer growing a line, a resize —
    //   snaps the viewport back to the REAL bottom, clamped inside the
    //   document. This is idempotent and self-correcting: SwiftUI's lazy
    //   stack scrolls by ESTIMATED heights and can land past the content
    //   (the blank-viewport bug on session restore); each materialization
    //   ticks the document frame and the clamp walks it back. Origin-only
    //   ticks are the user's own scrolling (or the elastic bounce) and are
    //   never touched — the wheel monitor unpins BEFORE AppKit scrolls.
    //
    // - UNPINNED: the reader is up in history. Reading position is measured
    //   from the BOTTOM (fraction of the scrollable range) because that is
    //   the only coordinate that survives a width reflow re-wrapping every
    //   row; the ledger replays through the reflow's settle window. Height
    //   changes leave the reader alone. Scrolling back to the tail re-pins.
    private var transcriptPinned = true {
        didSet {
            guard transcriptPinned != oldValue, !isTornDown else { return }
            // Publish the RELIABLE macOS pin state (the wheel monitor sets it)
            // so the composer folds its options strip while reading history.
            // The SwiftUI pin flag can't drive this on macOS — its bottom-edge
            // preference doesn't track AppKit-driven wheel scrolling.
            chatModel.transcriptAtBottom = transcriptPinned
        }
    }
    private var bottomLedgerFraction: CGFloat = 0
    private var lastClipSize: NSSize = .zero
    private var reflowSettleUntil: TimeInterval = 0
    private var isRestoringScroll = false
    /// A doc-frame shrink fired synchronously INSIDE a `setClipOrigin` restore
    /// (SwiftUI materialized the just-landed tail row and shrank an over-
    /// estimated document) and had to be deferred past the reentrancy guard.
    /// The restore re-runs the anchor before it unwinds, so the correction lands
    /// in the SAME runloop turn — no white frame reaches the screen.
    private var sawShrinkDuringRestore = false
    /// Recursion guard for that in-turn re-run (a shrink can cascade a couple of
    /// passes before the estimate settles); bounds it so it can never spin.
    private var restoreReentryDepth = 0
    private static let maxRestoreReentries = 4
    /// One deferred keep-bottom re-check is in flight (see `scheduleBottomReassert`).
    private var pendingBottomReassert = false
    private var lastWheelUpAt: TimeInterval = 0
    /// Timestamp of the most recent transcript wheel/trackpad tick (any
    /// direction, momentum included). The deferred overscroll heal reads it to
    /// tell a LIVE elastic rubber-band (leave it — AppKit springs it back) from
    /// a viewport stranded past the content with no gesture in flight (heal it).
    private var lastScrollWheelAt: TimeInterval = 0
    /// The composer's editor scroll view (NSTextView document) — the wheel
    /// monitor needs its frame to tell field scrolls from transcript scrolls,
    /// and the slash panel anchors above it.
    private weak var cachedComposerScrollView: NSScrollView?
    /// Periodic geometry sampler, running only when scroll diagnostics are on.
    private var diagTimer: Timer?
    private static let reflowSettleSeconds: TimeInterval = 0.4
    /// The deferred overscroll heal waits this long before pulling a stranded
    /// viewport back — comfortably past the elastic rubber-band's spring-back,
    /// so a live bounce settles on its own and the heal finds nothing to do.
    private static let overscrollHealDelay: TimeInterval = 0.35
    /// A wheel/momentum tick within this window of the heal means a gesture is
    /// still streaming (trackpad momentum fires every frame) — re-arm and wait
    /// it out rather than yank the rubber-band mid-flight.
    private static let scrollGestureIdleWindow: TimeInterval = 0.15

    /// How far the reader must scroll up before we treat it as viewing history
    /// (unpin + fold the options bar), rather than a nudge that stays at the
    /// tail. Approximately the slack between the tail message and the floating
    /// composer — the fixed content inset minus the composer's (strip-shown)
    /// height — plus a buffer. Deliberately approximate; the composer height is
    /// an estimate because the exact bar height isn't known on this side.
    private static let composerHeightEstimate: CGFloat = 84
    private static let historyScrollBuffer: CGFloat = 40
    private func historyScrollThreshold() -> CGFloat {
        let inset = cachedScrollView?.contentInsets.bottom ?? 0
        return max(0, inset - Self.composerHeightEstimate) + Self.historyScrollBuffer
    }

    // MARK: Resize coalescing
    //
    // A WIDTH change re-wraps the whole (possibly long) transcript — one full
    // MarkdownUI re-measure per row, with no width-keyed cache. A divider drag,
    // a window-edge drag, or the sidebar/dock split animation each fires those
    // per frame → a 0.25s reflow storm, and every intermediate frame also
    // re-anchors against SwiftUI's ESTIMATED lazy-stack height (the transient
    // blank-viewport / "white screen" on resize). So we COALESCE: while the
    // width is moving we FREEZE the hosting view at its last settled width
    // (the surface clips the overflow on a shrink, shows a gap on a grow — no
    // re-wrap), and apply the real width exactly once when it stops. Height
    // always tracks live (vertical growth is cheap and must stay glued to the
    // tail). One clean reflow + one deterministic re-anchor replaces the storm.
    private var lastAppliedContentWidth: CGFloat = 0
    /// Non-nil while a width change is being coalesced: the width the content
    /// stays laid out at until the resize settles.
    private var frozenContentWidth: CGFloat?
    private var resizeSettleTimer: Timer?
    /// Reflow this soon after the width stops moving. Short enough to feel
    /// immediate, long enough to bridge the split animation's per-frame ticks.
    private static let resizeSettleSeconds: TimeInterval = 0.08

    /// Places the hosting view every layout pass, coalescing width changes.
    private func layoutHostingView() {
        guard let hostingView else { return }
        let width = bounds.width

        // First real layout (0 → width): reflow directly, nothing to coalesce.
        if lastAppliedContentWidth == 0 {
            lastAppliedContentWidth = width
            hostingView.frame = bounds
            return
        }

        if let frozen = frozenContentWidth {
            // Mid-resize: hold the content width, let height follow, and push
            // the settle out — each layout() call here is another moved frame.
            hostingView.frame = NSRect(x: 0, y: 0, width: frozen, height: bounds.height)
            armResizeSettle()
            return
        }

        if abs(width - lastAppliedContentWidth) > 0.5 {
            beginResizeCoalescing()  // width just started moving — freeze at the old width
            hostingView.frame = NSRect(x: 0, y: 0, width: lastAppliedContentWidth, height: bounds.height)
        } else {
            hostingView.frame = bounds  // pure height change (composer grew) — cheap, live
        }
    }

    private func beginResizeCoalescing() {
        guard frozenContentWidth == nil else { return }
        frozenContentWidth = lastAppliedContentWidth
        // AppKit springs subviews on bounds change BEFORE layout(); drop the
        // width spring so only layoutHostingView() drives the content width,
        // and clip so the frozen-wide content can't bleed into the neighbour
        // pane while the surface is narrower than it.
        hostingView?.autoresizingMask = [.height]
        layer?.masksToBounds = true
        armResizeSettle()
    }

    private func armResizeSettle() {
        resizeSettleTimer?.invalidate()
        // `.common` modes so it still fires while a modal resize loop runs.
        let timer = Timer(timeInterval: Self.resizeSettleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleResize() }
        }
        RunLoop.current.add(timer, forMode: .common)
        resizeSettleTimer = timer
    }

    /// The resize stopped: apply the final width in ONE reflow, then re-anchor
    /// deterministically. A pinned reader scrolls to the materialized bottom
    /// (not the estimated tail, which would flash blank); an unpinned reader
    /// rides the existing bottom-ledger replay through the reflow's settle.
    private func settleResize() {
        resizeSettleTimer?.invalidate()
        resizeSettleTimer = nil
        guard let hostingView, frozenContentWidth != nil, !isTornDown else { return }
        frozenContentWidth = nil
        hostingView.autoresizingMask = [.width, .height]
        layer?.masksToBounds = false
        hostingView.frame = bounds                  // the single reflow, at the final width
        lastAppliedContentWidth = bounds.width
        if AcpScrollDiag.enabled {
            AcpScrollDiag.log(self, String(format: "settle w=%.1f pin=%d",
                                           bounds.width, transcriptPinned ? 1 : 0))
        }
        // Instant: this fires right after the one width reflow, so an animated
        // re-anchor would drag the whole transcript's re-wrap into its transaction.
        if transcriptPinned { chatModel.requestScrollToBottom(animated: false) }
    }

    /// The floating slash-command completion panel. Hosted in the WINDOW (not
    /// this surface) so it escapes the pane's clip — a tiny/short pane can't
    /// crush it — while staying a plain in-window view, so the composer keeps
    /// keyboard focus (unlike a popover, which stole it). See `updateSlashPanel`.
    private var slashPanelHost: NSHostingView<AnyView>?
    private static let slashPanelWidth: CGFloat = 380

    /// SwiftUI's ScrollView is backed by an NSScrollView; find it in the
    /// hosting hierarchy so AppKit-side scroll commands and geometry
    /// reporting can drive it. Re-resolved if SwiftUI rebuilds it.
    private func resolveScrollViewIfNeeded() {
        if let hostingView, cachedComposerScrollView?.window == nil {
            // nil or torn down — (re)find the composer's editor scroll view.
            cachedComposerScrollView = Self.findComposerScrollView(in: hostingView)
        }
        if let cached = cachedScrollView, cached.window != nil,
           observedDocView === cached.documentView { return }
        guard let hostingView,
            let found = Self.findTranscriptScrollView(in: hostingView) else { return }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let docFrameObserver { NotificationCenter.default.removeObserver(docFrameObserver) }
        if let clipFrameObserver { NotificationCenter.default.removeObserver(clipFrameObserver) }
        contentInsetObserver?.invalidate()
        if AcpScrollDiag.enabled {
            AcpScrollDiag.log(self, "resolve sv=\(AcpScrollDiag.tag(found)) "
                + "doc=\(AcpScrollDiag.tag(found.documentView)) "
                + "(was sv=\(AcpScrollDiag.tag(cachedScrollView)) doc=\(AcpScrollDiag.tag(observedDocView)))")
        }
        cachedScrollView = found
        observedDocView = found.documentView
        // A fresh scroll view starts pinned — but its ENTRY position can't be
        // left to SwiftUI: the initial-offset anchor lands ONCE, at estimated
        // geometry, and rows materializing right after grow the document with
        // no further SwiftUI anchoring (macOS scopes it out of size changes —
        // see acpTranscriptDefaultAnchor). Snap through the AppKit clamp below,
        // once the observers are registered.
        transcriptPinned = true
        bottomLedgerFraction = 0
        lastClipSize = .zero
        reflowSettleUntil = 0
        let clip = found.contentView
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] note in
            guard let clip = note.object as? NSClipView else { return }
            MainActor.assumeIsolated {
                self?.maintainBottomAnchor(clip: clip)
            }
        }
        // Viewport resizes (the composer growing a line, a vertical window
        // resize) change the clip's FRAME — AppKit does not post a bounds
        // change for frame-driven size changes, so without this observer a
        // pinned reader silently drifted off the tail whenever the composer
        // grew. (SwiftUI's own sizeChanges anchor proved unreliable here —
        // regression-tested in TranscriptScrollAnchorTests.)
        clip.postsFrameChangedNotifications = true
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: .main
        ) { [weak self] note in
            guard let clip = note.object as? NSClipView else { return }
            MainActor.assumeIsolated {
                self?.maintainBottomAnchor(clip: clip)
            }
        }
        // The composer's height (growing a line, folding the options strip,
        // adding attachments) rides the scroll view's bottom CONTENT INSET.
        // That changes the tail position but fires no clip/doc notification,
        // so a pinned reader would drift under the bar without this KVO.
        contentInsetObserver = found.observe(\.contentInsets, options: [.old, .new]) {
            [weak self] scroll, _ in
            MainActor.assumeIsolated {
                self?.maintainBottomAnchor(clip: scroll.contentView, insetChanged: true)
            }
        }
        // Document frame changes (streaming growth, lazy row materialization,
        // reflow after a width change) move the bottom without any clip
        // scroll — they must tick the ledger too.
        if let doc = found.documentView {
            doc.postsFrameChangedNotifications = true
            docFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: doc, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let clip = self?.cachedScrollView?.contentView else { return }
                    self?.maintainBottomAnchor(clip: clip, docFrameChanged: true)
                }
            }
        }
        // Land the entry on the real tail (see the pinned reset above): snap
        // now and across the materialization settle.
        snapToLiveBottom()
    }

    /// The keep-bottom tick, fired on clip bounds changes and document frame
    /// changes. See the ownership comment above `transcriptPinned`.
    private func maintainBottomAnchor(
        clip: NSClipView, docFrameChanged: Bool = false, insetChanged: Bool = false
    ) {
        guard !isTornDown, let doc = clip.documentView else { return }
        if isRestoringScroll {
            // We're inside a `setClipOrigin` restore. A doc-frame change arriving
            // now is SwiftUI relaying out synchronously in response to the scroll
            // we just applied — typically the over-estimated tail row settling to
            // its real (shorter) height, which strands the origin in blank. Don't
            // drop it: flag it so the restore re-runs the anchor before it
            // unwinds and heals within this same turn (see `setClipOrigin`).
            if docFrameChanged { sawShrinkDuringRestore = true }
            if AcpScrollDiag.enabled {
                AcpScrollDiag.log(self, "tick-in-restore \(docFrameChanged ? "D" : "-")")
            }
            return
        }
        let docH = doc.frame.height
        let visH = clip.bounds.height
        guard docH > 0, visH > 0, clip.bounds.width > 0 else { return }
        // The floating composer is a bottom CONTENT INSET (safeAreaInset), not
        // a smaller clip — so the tail sits `insetBottom` above the clip's
        // bottom edge (the last message clears the bar). The inset is part of
        // the scrollable range: pinned origin = docH - visH + insetBottom.
        let insetBottom = cachedScrollView?.contentInsets.bottom ?? 0
        let range = max(0, docH - visH + insetBottom)
        let now = ProcessInfo.processInfo.systemUptime

        let isFirstTick = lastClipSize == .zero
        let sizeChanged = clip.bounds.size != lastClipSize
        let widthChanged = abs(clip.bounds.width - lastClipSize.width) > 0.5
        if sizeChanged { lastClipSize = clip.bounds.size }

        if AcpScrollDiag.enabled {
            AcpScrollDiag.log(self, String(
                format: "tick %@%@%@ doc=%.1f vis=%.1f ins=%.1f org=%.1f rng=%.1f gap=%+.1f pin=%d",
                docFrameChanged ? "D" : "-", sizeChanged ? "C" : "-", insetChanged ? "I" : "-",
                docH, visH, insetBottom, clip.bounds.origin.y, range,
                clip.bounds.origin.y - range, transcriptPinned ? 1 : 0))
        }

        // Past the real content bottom is blank space — never a valid reading
        // position, pinned or not. SwiftUI's lazy stack scrolls by ESTIMATED
        // heights and overshoots on a fast down-flick; when the empty region
        // below materializes, docH shrinks and strands the origin under the
        // content. Pull it to the tail and re-pin (you ARE at the bottom).
        // Scoped to DOC-FRAME ticks: that is the materialization signal, and
        // it excludes both AppKit's origin-only elastic bounce AND clip-size
        // ticks (the composer growing / the options strip folding), which
        // must NOT re-pin a reader who is up in history near the bottom.
        if docFrameChanged, clip.bounds.origin.y > range + 1 {
            transcriptPinned = true
            bottomLedgerFraction = 0
            if setClipOrigin(clip, y: range) { scheduleBottomReassert() }
            return
        }

        if transcriptPinned {
            // Enter history mode only once the reader's OWN scroll (an origin-
            // only tick) has carried the viewport up past the slack between the
            // tail message and the floating composer — roughly `inset − composer
            // height`, plus a buffer — so a nudge within it doesn't hide the
            // bar. On the flip we anchor to CONTENT: leave the origin where they
            // scrolled and record the bottom-distance ledger from THERE, rather
            // than snapping to any bottom-relative offset.
            let scrolledUp = range - clip.bounds.origin.y
            if !docFrameChanged, !sizeChanged, !insetChanged, now >= reflowSettleUntil,
                scrolledUp > historyScrollThreshold() {
                transcriptPinned = false
                chatModel.noteUserScrolledUp()
                bottomLedgerFraction = range > 0 ? min(1, max(0, scrolledUp / range)) : 0
                return
            }
            // Idempotent tail-keeping: any SHAPE change snaps back to the real
            // bottom, held through the settle window (SwiftUI's lazy machinery
            // keeps nudging the origin for a few ticks after a shape change). An
            // origin-only tick within the slack is left alone — the reader's
            // small scroll stands, but they stay "at the tail".
            bottomLedgerFraction = 0
            if docFrameChanged || sizeChanged || insetChanged {
                reflowSettleUntil = now + Self.reflowSettleSeconds
                if setClipOrigin(clip, y: range) { scheduleBottomReassert() }
                // Arm the blank-heal even when the snap had nothing to move:
                // when the document SHRINKS under the viewport (a width reflow
                // re-wrapping to a much shorter doc), NSClipView auto-clamps
                // the origin into the new range ITSELF — no setClipOrigin of
                // ours, no SwiftUI scroll — and SwiftUI's lazy rows are left
                // materialized at the OLD world's offsets (proven by lldb layer
                // dumps: rows parked past the document end). The quiet-edge
                // check below is the only chance to catch that.
                armRenderReassert()
            } else if now < reflowSettleUntil {
                if setClipOrigin(clip, y: range) { scheduleBottomReassert() }
            } else if clip.bounds.origin.y > range + 1 {
                // Settled, pinned, origin-only tick — yet parked PAST the real
                // content (blank band above the composer). The docFrame heal
                // above never saw it: no shrink tick arrived (an overscroll
                // that didn't spring back, a lazy de-materialization that
                // shrank the doc between ticks, or a shrink dropped inside the
                // reentrancy guard). Heal on a deferred hop that outlasts the
                // elastic rubber-band, so a live bounce is never cut short.
                scheduleBottomReassert(afterGesture: true)
            }
        } else if widthChanged && !isFirstTick {
            // A width change re-wraps every row; bottom-distance is the only
            // coordinate that survives. Replay while the reflow settles
            // (re-armed on every tick of a live resize drag).
            reflowSettleUntil = now + Self.reflowSettleSeconds
            setClipOrigin(clip, y: range * (1 - bottomLedgerFraction))
        } else if now < reflowSettleUntil {
            setClipOrigin(clip, y: range * (1 - bottomLedgerFraction))
        } else {
            // Settled, unpinned: record the reading position. Landing back
            // near the tail re-pins (mirroring the SwiftUI-side preference
            // repin at ~60 pt so the two pinned flags flip together); the
            // wheel-up hysteresis keeps the first ticks of a flick away from
            // the bottom from re-pinning instantly.
            bottomLedgerFraction = range > 0
                ? min(1, max(0, (range - clip.bounds.origin.y) / range))
                : 0
            // Re-pin only on the reader's OWN scroll to the tail (an origin-
            // only tick). A shape tick that happens to leave them within 60 pt
            // — the options strip folding shrinks the range under them, a
            // streaming row grows the doc — must NOT re-pin; that was the
            // strip-toggle yank.
            if range - clip.bounds.origin.y < 60, !sizeChanged, !docFrameChanged,
                now - lastWheelUpAt > Self.reflowSettleSeconds {
                transcriptPinned = true
                bottomLedgerFraction = 0
            }
        }
    }

    /// Programmatic clip placement, always clamped inside the document — an
    /// unclamped origin can park the viewport past the content (the "blank
    /// area" bug). Setting the origin re-enters the bounds observer
    /// synchronously; `isRestoringScroll` keeps that inner pass inert. Returns
    /// whether the origin actually moved (a pinned tail-snap schedules a
    /// deferred re-check only when it did — see `scheduleBottomReassert`).
    @discardableResult
    private func setClipOrigin(_ clip: NSClipView, y: CGFloat) -> Bool {
        guard let doc = clip.documentView else { return false }
        let insetBottom = cachedScrollView?.contentInsets.bottom ?? 0
        let target = min(max(0, y), max(0, doc.frame.height - clip.bounds.height + insetBottom))
        guard abs(clip.bounds.origin.y - target) > 0.5 else { return false }
        if AcpScrollDiag.enabled {
            AcpScrollDiag.log(self, String(
                format: "set org %.1f -> %.1f (doc=%.1f)",
                clip.bounds.origin.y, target, doc.frame.height))
        }
        isRestoringScroll = true
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
        cachedScrollView?.reflectScrolledClipView(clip)
        isRestoringScroll = false
        // `reflectScrolledClipView` can synchronously shrink an over-estimated
        // document (the tail row materializing), which the reentrancy guard
        // above just deferred. Re-run the anchor NOW — same runloop turn, before
        // this frame draws — so the overshoot into blank is corrected in place
        // instead of flashing white until the next-turn reassert. Bounded so a
        // cascading re-estimate can never spin.
        if sawShrinkDuringRestore, restoreReentryDepth < Self.maxRestoreReentries {
            sawShrinkDuringRestore = false
            restoreReentryDepth += 1
            maintainBottomAnchor(clip: clip, docFrameChanged: true)
            restoreReentryDepth -= 1
        } else {
            sawShrinkDuringRestore = false
        }
        // An AppKit-driven scroll moves the pixels but not SwiftUI's OWN render
        // state — see armRenderReassert. Arm the deferred SwiftUI repaint for a
        // pinned tail; fire-time guards keep it away from an unpinned reader.
        if transcriptPinned { armRenderReassert() }
        return true
    }

    // MARK: SwiftUI render re-sync (the persistent-white-pane heal)
    //
    // PROVEN ON-DEVICE (lldb layer dumps + tracer, 2026-07-23/24): after a bulk
    // width reflow a pane can sit at the PERFECT clip origin yet render WHITE,
    // because SwiftUI's ScrollView never learned the clip moved: its lazy rows
    // stay materialized for a STALE believed offset — either dematerialized
    // entirely (empty document layer tree) or parked at the pre-reflow world's
    // coordinates PAST the new document end. The killer path doesn't even
    // involve our snaps: when the reflow SHRINKS the document, NSClipView
    // auto-clamps the origin itself, so neither we nor SwiftUI scrolls last.
    //
    // Stimuli DISPROVEN in-vivo on frozen white panes: posting live-scroll
    // notifications, doc/hosting setNeedsLayout, and a synthetic
    // `scrollWheel(with:)` call (window-less events don't enter SwiftUI's
    // pipeline). `proxy.scrollTo(bottomID)` heals only SOMETIMES — a fully
    // dematerialized pane has no sentinel to target, so it no-ops. What the
    // heal drives instead: the scroll-to-bottom token now lands on SwiftUI's
    // native `ScrollPosition.scrollTo(edge: .bottom)` (macOS 15+), an
    // edge-based command that exists regardless of materialization and moves
    // belief + lazy window + clip together.
    //
    // So: on the quiet edge after pinned churn, CHECK whether the viewport
    // actually has painted content (walk the document's layer tree — the same
    // measurement that diagnosed this). Only a genuinely blank pane is healed,
    // and every step logs its verdict for the next log read.

    private var renderReassertTimer: Timer?
    private var lastRenderReassertAt: TimeInterval = 0
    /// Standing watchdog: the churn-armed check above can only run where a
    /// shape tick arms it; this sweeps every pane on a slow beat so NO path —
    /// known or unknown — can leave a blank pane undetected for more than
    /// ~1.5s. The blank check is cheap for healthy panes (first contents-
    /// bearing layer in the viewport band short-circuits the walk).
    private var blankWatchdogTimer: Timer?
    private var rebuildCount = 0
    private var lastRebuildAt: TimeInterval = 0
    /// Quiet window after the last pinned shape tick before the blank check
    /// runs (re-armed by every tick while a reflow/replay churns).
    private static let renderReassertQuiet: TimeInterval = 0.3
    /// Floor between two heal sequences.
    private static let renderReassertMinInterval: TimeInterval = 1.0
    /// Floor between two nuclear rebuilds of the same pane.
    private static let rebuildMinInterval: TimeInterval = 5.0

    private func armRenderReassert() {
        renderReassertTimer?.invalidate()
        let timer = Timer(timeInterval: Self.renderReassertQuiet, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireRenderReassert() }
        }
        RunLoop.current.add(timer, forMode: .common)
        renderReassertTimer = timer
    }

    private func installBlankWatchdog() {
        guard blankWatchdogTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireRenderReassert() }
        }
        RunLoop.main.add(timer, forMode: .common)
        blankWatchdogTimer = timer
    }

    private func fireRenderReassert() {
        renderReassertTimer?.invalidate()
        renderReassertTimer = nil
        guard !isTornDown, transcriptPinned, !isHiddenOrHasHiddenAncestor else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A user mid-gesture repaints through their own scroll — stay out.
        guard now - lastScrollWheelAt > 0.5 else { return }
        guard now - lastRenderReassertAt > Self.renderReassertMinInterval else { return }
        guard transcriptLooksBlank() else { return }
        lastRenderReassertAt = now
        if AcpScrollDiag.enabled { AcpScrollDiag.log(self, "BLANK -> edge re-ground") }
        chatModel.requestScrollToBottom(animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.isTornDown, self.transcriptPinned else { return }
            guard self.transcriptLooksBlank() else {
                if AcpScrollDiag.enabled { AcpScrollDiag.log(self, "healed by edge scroll") }
                return
            }
            // The edge command no-ops on about half the wedged panes (verdict
            // logs) — a ScrollView whose stale belief says "already at the
            // bottom edge" can't be talked down. Replace it: the epoch bump
            // discards the whole subtree and rebuilds it on the initial-render
            // path, which cannot inherit any of the wedged scroll state.
            let now2 = ProcessInfo.processInfo.systemUptime
            guard now2 - self.lastRebuildAt > Self.rebuildMinInterval else { return }
            self.lastRebuildAt = now2
            self.rebuildCount += 1
            if AcpScrollDiag.enabled {
                AcpScrollDiag.log(self, "still BLANK -> REBUILD #\(self.rebuildCount)")
            }
            self.chatModel.forceTranscriptRebuild()
            self.scheduleScrollResolution()   // re-find + re-anchor the fresh scroll view
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, !self.isTornDown else { return }
                if AcpScrollDiag.enabled {
                    AcpScrollDiag.log(self, self.transcriptLooksBlank()
                        ? "STILL BLANK after rebuild" : "healed by rebuild")
                }
            }
        }
    }

    /// TRUE when the transcript viewport (the band above the composer) shows
    /// no painted layer at all — the layer-tree measurement that separated the
    /// white panes from healthy ones in the lldb dumps (healthy viewports have
    /// dozens of contents-bearing layers; white ones have zero anywhere near).
    /// Short documents (fresh agents) are never "blank": nothing to strand.
    private func transcriptLooksBlank() -> Bool {
        guard let scroll = cachedScrollView,
            let doc = scroll.contentView.documentView,
            let rootLayer = doc.layer else { return false }
        let clip = scroll.contentView
        guard doc.frame.height > clip.bounds.height * 1.5 else { return false }
        let visTop = clip.bounds.origin.y
        let visBottom = visTop + clip.bounds.height - scroll.contentInsets.bottom
        var stack: [(CALayer, CGFloat)] = [(rootLayer, 0)]
        var visited = 0
        while let (layer, absY) = stack.popLast() {
            visited += 1
            if visited > 4000 { return false }   // huge live tree: assume painted
            for sub in layer.sublayers ?? [] {
                let subY = absY + sub.frame.origin.y
                if sub.contents != nil, !sub.isHidden,
                    subY + sub.frame.height > visTop, subY < visBottom {
                    return false                 // real pixels in the viewport
                }
                stack.append((sub, subY))
            }
        }
        return true
    }


    /// Re-run the keep-bottom clamp on the NEXT runloop turn, after any layout
    /// the just-applied pinned anchor kicked off has settled.
    ///
    /// A pinned tail-snap calls `reflectScrolledClipView`, which can make
    /// SwiftUI's lazy stack materialize the freshly-landed tail row
    /// SYNCHRONOUSLY — shrinking a document whose off-screen (or not-yet-
    /// materialized) rows were over-estimated. That shrink posts a doc-frame
    /// notification WHILE `isRestoringScroll` is set, so `maintainBottomAnchor`
    /// drops it; with nothing streaming to tick again (e.g. right after a send,
    /// before the agent answers), the viewport is stranded in the blank band
    /// below the now-shorter content — the intermittent white-screen-on-send.
    ///
    /// This fires OUTSIDE the reentrancy window, reads the settled height, and
    /// heals ONLY a viewport left past the real content (never a settled tail,
    /// never an in-flight elastic bounce — that springs back well under this
    /// hop's horizon). Idempotent: it re-anchors, and reschedules, only while
    /// the origin is still off, so it self-terminates.
    ///
    /// `afterGesture` handles the sibling case: a viewport stranded past the
    /// content by a user OVERSCROLL that never sprang back (rather than by a
    /// tail-snap's own reentrancy). It waits `overscrollHealDelay` — past the
    /// elastic rubber-band — before touching anything, and if a wheel/momentum
    /// tick landed inside `scrollGestureIdleWindow` it re-arms instead of
    /// yanking a still-live bounce. Either way it pulls back ONLY while the
    /// origin is genuinely past the settled content, so a bounce that already
    /// sprang home is a no-op.
    private func scheduleBottomReassert(afterGesture: Bool = false) {
        guard !pendingBottomReassert else { return }
        pendingBottomReassert = true
        let delay: TimeInterval = afterGesture ? Self.overscrollHealDelay : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pendingBottomReassert = false
            guard !self.isTornDown, self.transcriptPinned, !self.isRestoringScroll,
                let clip = self.cachedScrollView?.contentView,
                let doc = clip.documentView else { return }
            let insetBottom = self.cachedScrollView?.contentInsets.bottom ?? 0
            let range = max(0, doc.frame.height - clip.bounds.height + insetBottom)
            guard clip.bounds.origin.y > range + 1 else { return }
            if afterGesture, ProcessInfo.processInfo.systemUptime - self.lastScrollWheelAt
                < Self.scrollGestureIdleWindow {
                // Still mid-gesture (trackpad momentum): let it settle first.
                self.scheduleBottomReassert(afterGesture: true)
                return
            }
            if self.setClipOrigin(clip, y: range) { self.scheduleBottomReassert() }
        }
    }

    /// Drive an explicit "jump to the live bottom" through the AppKit anchor —
    /// the macOS substitute for the SwiftUI `proxy.scrollTo` we opt out of (that
    /// one scrolls by ESTIMATED heights and overshoots into blank). Every
    /// `requestScrollToBottom` funnels here: the transcript's jump-to-live
    /// button, and `settleResize` after a resize / Focus↔Parallel switch.
    ///
    /// Snaps to the real, clamped bottom NOW, holds through the reflow settle
    /// (a mode switch re-wraps every row over the next runloops, changing docH),
    /// and re-snaps once that lands so we settle on the reflowed tail — not the
    /// pre-reflow one, and never on SwiftUI's estimated overshoot.
    private func snapToLiveBottom() {
        guard !isTornDown else { return }
        // The token often fires right after a big relayout (mode switch); if
        // SwiftUI rebuilt the scroll view underneath, re-find it first so the
        // snap (and the observers behind the keep-bottom ticks) act on the LIVE
        // hierarchy, never a stale cache.
        resolveScrollViewIfNeeded()
        if AcpScrollDiag.enabled { AcpScrollDiag.log(self, "token-snap") }
        reflowSettleUntil = ProcessInfo.processInfo.systemUptime + Self.reflowSettleSeconds
        snapClipToBottomIfPinned()
        // The reflow (new width → new docH) lands over the next runloop turns;
        // re-snap across a couple of them so we track it down to the settled tail.
        for delay in [0.0, 0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.snapClipToBottomIfPinned()
            }
        }
    }

    /// Clamp the transcript clip to the real bottom (`docH - visH + inset`), but
    /// only while still pinned and outside a restore — the shared tail-snap the
    /// jump-to-live path reuses.
    private func snapClipToBottomIfPinned() {
        guard !isTornDown, transcriptPinned, !isRestoringScroll,
            let clip = cachedScrollView?.contentView,
            let doc = clip.documentView else { return }
        let insetBottom = cachedScrollView?.contentInsets.bottom ?? 0
        let range = max(0, doc.frame.height - clip.bounds.height + insetBottom)
        if setClipOrigin(clip, y: range) { scheduleBottomReassert() }
    }

    // MARK: Scroll diagnostics (opt-in)

    private func installDiagSamplerIfNeeded() {
        guard AcpScrollDiag.enabled, diagTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.logDiagSample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagTimer = timer
    }

    /// One line per second per surface: the full keep-bottom geometry PLUS the
    /// measured bottom of the lowest materialized descendant (`mat`) — the
    /// number that distinguishes "viewport past the content" (org > rng) from
    /// "document itself inflated past its real rows" (org == rng, mat ≪ doc,
    /// nothing materialized inside the viewport), and shows dead machinery
    /// (alive/sameDoc flags) that event logs go silent on.
    private func logDiagSample() {
        guard !isTornDown, AcpScrollDiag.enabled else { return }
        guard let scroll = cachedScrollView else {
            AcpScrollDiag.log(self, "sample NO-SCROLLVIEW win=\(window != nil ? 1 : 0)")
            return
        }
        let clip = scroll.contentView
        guard let doc = clip.documentView else {
            AcpScrollDiag.log(self, "sample NO-DOC")
            return
        }
        let insetBottom = scroll.contentInsets.bottom
        let range = max(0, doc.frame.height - clip.bounds.height + insetBottom)
        let mat = AcpScrollDiag.materializedBottom(of: doc)
        AcpScrollDiag.log(self, String(
            format: "sample doc=%.1f mat=%.1f vis=%.1f ins=%.1f org=%.1f rng=%.1f "
                + "gap=%+.1f pin=%d alive=%d sameDoc=%d hidden=%d",
            doc.frame.height, mat, clip.bounds.height, insetBottom,
            clip.bounds.origin.y, range, clip.bounds.origin.y - range,
            transcriptPinned ? 1 : 0, scroll.window != nil ? 1 : 0,
            observedDocView === doc ? 1 : 0, isHiddenOrHasHiddenAncestor ? 1 : 0))
    }

    /// The transcript's scroll view: the TALLEST scroller whose document is
    /// not a text view. The hierarchy holds several NSScrollViews — the
    /// composer's NSTextView editor, the slash-command panel, chip rows —
    /// so "first found" could latch the bottom ledger onto the composer:
    /// that fought the field's own internal scrolling AND left the
    /// transcript uncorrected (the blank-viewport bugs).
    private static func findTranscriptScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        walkTopLevelScrollViews(in: view) { scroll in
            guard !(scroll.documentView is NSTextView) else { return }
            if scroll.frame.height > (best?.frame.height ?? 0) { best = scroll }
        }
        return best
    }

    /// The composer's editor scroll view: the one documenting an NSTextView.
    private static func findComposerScrollView(in view: NSView) -> NSScrollView? {
        var found: NSScrollView?
        walkTopLevelScrollViews(in: view) { scroll in
            if found == nil, scroll.documentView is NSTextView { found = scroll }
        }
        return found
    }

    /// Visit scroll views without descending INTO them — code blocks nest
    /// scroll views inside the transcript's document, and those must never
    /// win the transcript resolution.
    private static func walkTopLevelScrollViews(in view: NSView, _ visit: (NSScrollView) -> Void) {
        if let scroll = view as? NSScrollView {
            visit(scroll)
            return
        }
        for sub in view.subviews { walkTopLevelScrollViews(in: sub, visit) }
    }

    // MARK: - Floating slash-command panel

    /// Build / update / tear down the completion panel from the session's
    /// derived match set. Hosted in the window's content view so it floats
    /// above the tiled panes and can spill past this pane's bounds — while
    /// staying a plain in-window view, so the composer keeps keyboard focus
    /// (a popover stole it).
    /// `explicitDraft` is the freshly-emitted `$composerDraft` value on the
    /// synchronous typing path (the property's willSet hasn't landed yet); nil
    /// on the availability/selection path, which reads the settled property.
    private func updateSlashPanel(draft explicitDraft: String?) {
        guard !isTornDown, let session = chatModel.session,
            let contentView = window?.contentView, !isHiddenOrHasHiddenAncestor
        else { removeSlashPanel(); return }
        let matches = session.slashCommandMatches(for: explicitDraft ?? session.composerDraft)
        guard !matches.isEmpty else { removeSlashPanel(); return }

        // Resolve the composer anchor ON DEMAND. Waiting for the cache to be
        // warmed by a layout()/scroll-resolution pass could leave the panel
        // hidden for seconds after "/" (the reported latency) if no such pass
        // happened to fire — typing doesn't resize the surface.
        if cachedComposerScrollView?.window == nil, let hostingView {
            cachedComposerScrollView = Self.findComposerScrollView(in: hostingView)
        }

        let panel = AcpSlashCommandPanel(
            matches: matches,
            selection: min(chatModel.slashSelection, matches.count - 1),
            accept: { [weak self] command in
                guard let self else { return }
                self.chatModel.session?.acceptSlashCommand(command)
                self.requestComposerFocus()
            })
        .frame(width: Self.slashPanelWidth)
        // Match the pane's pinned light/dark so system colors resolve legibly.
        .environment(\.colorScheme, isDarkAppearance ? .dark : .light)

        let host: NSHostingView<AnyView>
        if let existing = slashPanelHost, existing.superview === contentView {
            host = existing
            host.rootView = AnyView(panel)
        } else {
            removeSlashPanel()
            host = NSHostingView(rootView: AnyView(panel))
            // Intrinsic sizing so `fittingSize` measures the panel; we still
            // place it by explicit frame (autoresizing mask stays empty).
            host.sizingOptions = [.intrinsicContentSize]
            slashPanelHost = host
            contentView.addSubview(host)
        }
        positionSlashPanel(host, in: contentView)
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Anchor the panel just above the composer field, left-aligned to it,
    /// clamped inside the window (dropping below the field only if there is
    /// truly no room above — a window parked at the top of the screen).
    private func positionSlashPanel(_ host: NSHostingView<AnyView>, in contentView: NSView) {
        // Prefer the composer field; if it isn't resolved yet, fall back to
        // this pane's bottom edge (the composer is docked there) so the panel
        // still appears immediately rather than waiting on the anchor.
        let anchor: NSRect
        if let editor = cachedComposerScrollView, editor.window === window {
            anchor = editor.convert(editor.bounds, to: contentView)
        } else {
            let strip = NSRect(x: 6, y: bounds.height - 46, width: max(0, bounds.width - 12), height: 40)
            anchor = convert(strip, to: contentView)
        }
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 1 { size.width = Self.slashPanelWidth }
        if size.height < 1 { size.height = 220 }
        let bounds = contentView.bounds
        var x = min(max(anchor.minX, bounds.minX + 8), bounds.maxX - size.width - 8)
        if !x.isFinite { x = bounds.minX + 8 }

        // Sit the panel's bottom 6 pt above the field's TOP edge, clamped
        // inside the window; drop below the field only if there is genuinely
        // no room above. Which screen direction is "above" flips with the
        // container's coordinate system (window content view: y-up; a flipped
        // host, as in tests: y-down).
        let gap: CGFloat = 6
        let y: CGFloat
        if contentView.isFlipped {
            let above = anchor.minY - gap - size.height
            let below = anchor.maxY + gap
            y = above >= bounds.minY + 8 ? above
                : min(below, bounds.maxY - 8 - size.height)
        } else {
            let above = anchor.maxY + gap
            let below = anchor.minY - gap - size.height
            y = above + size.height <= bounds.maxY - 8 ? above
                : max(below, bounds.minY + 8)
        }
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func removeSlashPanel() {
        slashPanelHost?.removeFromSuperview()
        slashPanelHost = nil
    }

    // MARK: - File preview

    /// Tool-card / diff path click → the shared preview dock, through the
    /// host-provided context (nil = links render but no-op; host wires the
    /// context exactly like it does for terminal panes).
    private func openFilePreview(path: String, line: Int?) {
        guard let context = pathPreviewContext else { return }
        WorkspaceWindow.openPreview(path: path, line: line, context: context)
    }
}

/// On-device geometry tracer for the white-viewport bug family. This family
/// has never reproduced headless (three probes: plain-text test rows estimate
/// exactly; only the real app's async MarkdownUI rows diverge), so when it
/// strikes, the live app's own numbers are the only useful evidence. Off by
/// default — enable with
/// `defaults write com.bento.menubar.acp AcpScrollDiag -bool YES`,
/// relaunch the GUI, reproduce, then read /tmp/bento-acp-scroll-diag.log
/// (truncated on every launch).
@MainActor
private enum AcpScrollDiag {
    static let enabled = UserDefaults.standard.bool(forKey: "AcpScrollDiag")
    private static let startUptime = ProcessInfo.processInfo.systemUptime
    private static let handle: FileHandle? = {
        let path = "/tmp/bento-acp-scroll-diag.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    /// Stable short identity for correlating lines (surfaces, scroll views).
    static func tag(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xFFFF, radix: 16)
    }

    static func log(_ surface: AnyObject, _ line: String) {
        guard enabled, let handle else { return }
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        handle.write(Data("+\(String(format: "%9.3f", t)) [\(tag(surface))] \(line)\n".utf8))
    }

    /// Bottom edge, in document coordinates, of the LOWEST materialized
    /// descendant — the real content bottom, versus the document's (possibly
    /// estimated) claimed height. Bounded walk; diagnostics-only cost.
    static func materializedBottom(of doc: NSView) -> CGFloat {
        var maxY: CGFloat = 0
        var visited = 0
        func walk(_ view: NSView, _ depth: Int) {
            guard depth < 10, visited < 4000 else { return }
            for sub in view.subviews where !sub.isHidden {
                visited += 1
                maxY = max(maxY, doc.convert(sub.bounds, from: sub).maxY)
                walk(sub, depth + 1)
            }
        }
        walk(doc, 0)
        return maxY
    }
}

/// Full-pane "Drop image to attach" catcher, shown only while an image drag
/// hovers the chat surface. Being the topmost subview it wins AppKit's
/// drag-destination hit-test everywhere in the pane — including over the
/// composer's field editor, which would otherwise insert the file path.
private final class AcpDropTargetOverlay: NSView {
    var onPerform: ((NSDraggingInfo) -> Bool)?
    var onFinish: (() -> Void)?
    /// True once this overlay became the drag's destination (the surface's
    /// draggingExited then means handoff, not departure).
    private(set) var isActive = false

    private let label = NSTextField(labelWithString: "Drop image to attach")

    init(frame: NSRect, types: [NSPasteboard.PasteboardType]) {
        super.init(frame: frame)
        registerForDraggedTypes(types)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        applyPalette()

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .controlAccentColor
        label.sizeToFit()
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        label.frame.origin = NSPoint(
            x: (bounds.width - label.frame.width) / 2,
            y: (bounds.height - label.frame.height) / 2)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    private func applyPalette() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isActive = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isActive = false
        onFinish?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isActive = false
        onFinish?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerform?(sender) ?? false
    }
}

#endif
