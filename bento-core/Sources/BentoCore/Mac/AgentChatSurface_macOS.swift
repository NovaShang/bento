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
        rightHoldTimer?.invalidate()
    }

    /// Attach (or replace) the session after init — e.g. the pane was created
    /// before the agent finished spawning and showed the starting placeholder.
    public func attach(_ session: AgentSessionViewModel) {
        guard !isTornDown else { return }
        chatModel.session = session
        bindSession(session)
    }

    private func bindSession(_ session: AgentSessionViewModel?) {
        sessionBag.removeAll()
        _ = session
    }

    /// Explicitly release everything host-visible. Idempotent (host calls
    /// this when the pane closes).
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
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
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installEventMonitorIfNeeded()
        } else {
            removeEventMonitor()
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
            // beats the ledger.
            if isEventInside(event) {
                reflowSettleUntil = 0
                if event.scrollingDeltaY > 0 {
                    chatModel.noteUserScrolledUp()
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
        let menu = NSMenu()
        let copy = NSMenuItem(
            title: "Copy Transcript", action: #selector(contextCopyTranscript), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let paste = NSMenuItem(title: "Paste", action: #selector(contextPaste), keyEquivalent: "")
        paste.target = self
        menu.addItem(paste)
        menu.popUp(positioning: nil, at: convert(downEvent.locationInWindow, from: nil), in: self)
    }

    @objc private func contextCopyTranscript() {
        guard let text = readScrollback(), !text.isEmpty else { return }
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

    // MARK: Bottom-anchored reading position
    //
    // Chat reading position is measured from the BOTTOM of the transcript
    // (as a fraction of the scrollable range; 0 = pinned to the tail),
    // because that is the only measure that stays meaningful when a width
    // change reflows every row. AppKit/SwiftUI preserve the TOP offset
    // through a reflow, which threw the viewport to the middle of the
    // transcript — or past the end into blank space. While a reflow
    // settles, every geometry tick REPLAYS the ledger position (clamped);
    // once settled, real scrolls update the ledger instead. A user wheel
    // or a programmatic row-nav cancels the replay window: intent wins.
    private var bottomLedgerFraction: CGFloat = 0
    private var lastClipSize: NSSize = .zero
    private var reflowSettleUntil: TimeInterval = 0
    private var isRestoringScroll = false
    private static let reflowSettleSeconds: TimeInterval = 0.4

    /// SwiftUI's ScrollView is backed by an NSScrollView; find it in the
    /// hosting hierarchy so AppKit-side scroll commands and geometry
    /// reporting can drive it. Re-resolved if SwiftUI rebuilds it.
    private func resolveScrollViewIfNeeded() {
        if let cached = cachedScrollView, cached.window != nil,
           observedDocView === cached.documentView { return }
        guard let hostingView, let found = Self.findScrollView(in: hostingView) else { return }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let docFrameObserver { NotificationCenter.default.removeObserver(docFrameObserver) }
        cachedScrollView = found
        observedDocView = found.documentView
        // Fresh scroll view = fresh layout at the bottom (defaultScrollAnchor).
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
                    self?.maintainBottomAnchor(clip: clip)
                }
            }
        }
    }

    /// The ledger tick: replay the bottom-relative position while a width
    /// reflow settles, record it otherwise. Setting the bounds origin here
    /// re-enters the bounds observer synchronously — `isRestoringScroll`
    /// keeps that inner pass report-only.
    private func maintainBottomAnchor(clip: NSClipView) {
        guard !isTornDown, !isRestoringScroll, let doc = clip.documentView else { return }
        let docH = doc.frame.height
        let visH = clip.bounds.height
        let width = clip.bounds.width
        guard docH > 0, visH > 0, width > 0 else { return }
        let range = max(0, docH - visH)
        let now = ProcessInfo.processInfo.systemUptime

        // Width changes reflow every row, so the bottom-relative replay always
        // has to run. A pure HEIGHT change (the composer's options strip
        // auto-hiding, the composer growing a line, a vertical window resize)
        // is different: it must keep a PINNED reader at the tail, but a reader
        // scrolled UP into history has to keep their own position — re-anchoring
        // them bottom-relative yanked the viewport (the strip-toggle scroll
        // jump). So a height-only change only arms the replay when pinned.
        // Re-armed on every tick of a live drag; the first tick ever (zero
        // size) is initial layout.
        if clip.bounds.size != lastClipSize {
            let widthChanged = abs(clip.bounds.width - lastClipSize.width) > 0.5
            let pinned = bottomLedgerFraction < 0.001
            if lastClipSize != .zero && (widthChanged || pinned) {
                reflowSettleUntil = now + Self.reflowSettleSeconds
            }
            lastClipSize = clip.bounds.size
        }

        if now < reflowSettleUntil {
            let target = max(0, range * (1 - bottomLedgerFraction))
            guard abs(clip.bounds.origin.y - target) > 0.5 else { return }
            isRestoringScroll = true
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
            cachedScrollView?.reflectScrolledClipView(clip)
            isRestoringScroll = false
        } else {
            bottomLedgerFraction = range > 0
                ? min(1, max(0, (range - clip.bounds.origin.y) / range))
                : 0
        }
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    /// The transcript as plain text, role-prefixed — the chat analogue of the
    /// terminal scrollback read (turn-nav scans, copy).
    func readScrollback() -> String? {
        guard let session = chatModel.session else { return nil }
        var lines: [String] = []
        for item in session.items {
            if let message = item as? MessageItem {
                let prefix: String
                switch message.role {
                case .user: prefix = "You: "
                case .agent: prefix = "Agent: "
                case .thought: prefix = "Thought: "
                }
                let text = message.fullText
                if !text.isEmpty { lines.append(prefix + text) }
            } else if let tool = item as? ToolCallItem {
                lines.append("[tool:\(tool.kind.rawValue)] \(tool.title) (\(tool.status.rawValue))")
                let output = tool.textOutput
                if !output.isEmpty { lines.append(output) }
            } else if let notice = item as? NoticeItem {
                lines.append("[\(notice.severity == .error ? "error" : "info")] \(notice.message)")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
