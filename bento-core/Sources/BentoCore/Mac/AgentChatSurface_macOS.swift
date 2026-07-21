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
                self?.transcriptPinned = true
                self?.bottomLedgerFraction = 0
                self?.reflowSettleUntil = 0
            }
            .store(in: &modelBag)
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        // teardown() normally already ran; this is the fallback so a surface
        // dropped without teardown can't leak its app-wide event monitor.
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let docFrameObserver { NotificationCenter.default.removeObserver(docFrameObserver) }
        if let clipFrameObserver { NotificationCenter.default.removeObserver(clipFrameObserver) }
        rightHoldTimer?.invalidate()
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
        hostingView?.frame = bounds
        resolveScrollViewIfNeeded()
        // The composer field moves as the pane resizes / the field grows a
        // line; keep the floating panel glued to it.
        if let host = slashPanelHost, let contentView = window?.contentView {
            positionSlashPanel(host, in: contentView)
        }
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
                if event.scrollingDeltaY > 0 {
                    lastWheelUpAt = ProcessInfo.processInfo.systemUptime
                    if transcriptPinned {
                        transcriptPinned = false
                        chatModel.noteUserScrolledUp()
                    }
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
    private var lastWheelUpAt: TimeInterval = 0
    /// The composer's editor scroll view (NSTextView document) — the wheel
    /// monitor needs its frame to tell field scrolls from transcript scrolls,
    /// and the slash panel anchors above it.
    private weak var cachedComposerScrollView: NSScrollView?
    private static let reflowSettleSeconds: TimeInterval = 0.4

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
        cachedScrollView = found
        observedDocView = found.documentView
        // Fresh scroll view = fresh layout at the bottom (defaultScrollAnchor).
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
    }

    /// The keep-bottom tick, fired on clip bounds changes and document frame
    /// changes. See the ownership comment above `transcriptPinned`.
    private func maintainBottomAnchor(clip: NSClipView, docFrameChanged: Bool = false) {
        guard !isTornDown, !isRestoringScroll, let doc = clip.documentView else { return }
        let docH = doc.frame.height
        let visH = clip.bounds.height
        guard docH > 0, visH > 0, clip.bounds.width > 0 else { return }
        let range = max(0, docH - visH)
        let now = ProcessInfo.processInfo.systemUptime

        let isFirstTick = lastClipSize == .zero
        let sizeChanged = clip.bounds.size != lastClipSize
        let widthChanged = abs(clip.bounds.width - lastClipSize.width) > 0.5
        if sizeChanged { lastClipSize = clip.bounds.size }

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
            setClipOrigin(clip, y: range)
            return
        }

        if transcriptPinned {
            // Idempotent tail-keeping: any shape change snaps back to the
            // real bottom, and holds it through the settle window — SwiftUI's
            // lazy machinery keeps adjusting the origin (estimate-based) for
            // a few ticks after a shape change, and those adjustments drift
            // the tail. Origin-only ticks OUTSIDE the window are the user's
            // own scrolling / elastic bounce and pass untouched — unpinning
            // is the wheel monitor's job (which also cancels the window).
            bottomLedgerFraction = 0
            if docFrameChanged || sizeChanged {
                reflowSettleUntil = now + Self.reflowSettleSeconds
                setClipOrigin(clip, y: range)
            } else if now < reflowSettleUntil {
                setClipOrigin(clip, y: range)
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
    /// synchronously; `isRestoringScroll` keeps that inner pass inert.
    private func setClipOrigin(_ clip: NSClipView, y: CGFloat) {
        guard let doc = clip.documentView else { return }
        let target = min(max(0, y), max(0, doc.frame.height - clip.bounds.height))
        guard abs(clip.bounds.origin.y - target) > 0.5 else { return }
        isRestoringScroll = true
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
        cachedScrollView?.reflectScrolledClipView(clip)
        isRestoringScroll = false
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
