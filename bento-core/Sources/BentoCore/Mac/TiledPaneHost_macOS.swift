#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI

/// iTerm2-style TILED multi-pane host for macOS. Every workspace pane is shown
/// at once, laid out proportionally from its layout-tree cell, each pane an
/// `AgentChatSurface` bound to its agent runtime. The store owns the split
/// layout and we mirror it.
///
/// iTerm2-parity features:
///   - per-pane title bar (command + title), accent-highlighted when active
///   - click a pane to focus it; active pane gets an accent border
///   - the title-bar Focus button flips the whole workspace to Focus mode on
///     that pane (Parallel ⇄ Focus is the view-mode toggle, not a per-pane zoom)
///   - drag the divider between adjacent panes to resize (sends `resize-pane`)
///   - drag a pane's title bar onto another pane to swap with it or dock
///     beside it (VS Code-style drop zones)
///   - menu / keyboard split, close, and next/prev-pane navigation
@MainActor
public final class TiledPaneHost: NSView, NSMenuDelegate {
    let viewModel: WorkspaceViewModel
    private var theme: CanvasTheme
    private var cells: [PaneID: PaneCell] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Per-pane Combine subscriptions, keyed by pane so they are cancelled when
    /// the pane's cell is torn down (storing them in the host-wide `cancellables`
    /// let them accumulate over a session of pane churn).
    private var cellBags: [PaneID: Set<AnyCancellable>] = [:]
    /// Block-observer tokens for the theme/font notifications. `removeObserver(self)`
    /// does NOT remove block observers, so the tokens must be stored and removed
    /// explicitly (mirrors the surface's `renderObservers`).
    private var themeObservers: [NSObjectProtocol] = []
    private let dividerOverlay = DividerOverlay()

    /// Hold-to-talk voice (right-click-and-hold a pane). One controller per
    /// window; the overlay is shown on top of the panes while recording.
    private let voiceController = MacVoiceController()
    private var voiceOverlay: MacVoiceOverlay?
    /// Centered, interactive overlay card for the right-swipe "AI correct" preview
    /// (vs `voiceOverlay`, which is the passive recording compass).
    private var voicePreview: NSView?

    /// The live "Move to Session" submenu, populated lazily via `menuNeedsUpdate`
    /// so the session list reflects the refresh kicked when the menu opened —
    /// otherwise the first open captures a still-cold cache and shows empty.
    private weak var moveToSessionMenu: NSMenu?

    /// Tear down every pane's chat surface before the window/view hierarchy is
    /// released. Call from windowWillClose.
    public func teardown() {
        cancellables.removeAll()
        cellBags.removeAll()
        themeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        themeObservers.removeAll()
        for (_, cell) in cells { cell.surface.teardown() }
    }

    /// Title-strip height for every tiled pane (a fixed point size — panes
    /// are laid out fractionally, not on a character grid).
    static let fallbackTitleBarHeight: CGFloat = 20
    /// Focus mode presents one pane full-window, so it gets a roomier header
    /// (title + state + the pane-scoped controls) instead of the thin strip.
    static let focusHeaderHeight: CGFloat = 40
    /// Horizontal inset between a pane's surface and its container edge, so
    /// abutting containers read as separate panes.
    static let paneGutter: CGFloat = 3

    /// NSColor from a 0xRRGGBB terminal color.
    static func bgColor(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    public init(viewModel: WorkspaceViewModel, theme: CanvasTheme) {
        self.viewModel = viewModel
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        // Paint the host in the terminal background color (not black) so the
        // one-cell divider column between side-by-side panes reads as the pane
        // background bleeding through, not an empty gap. Geometry is unchanged.
        layer?.backgroundColor = Self.bgColor(theme.background).cgColor

        dividerOverlay.host = self
        dividerOverlay.autoresizingMask = [.width, .height]
        addSubview(dividerOverlay)

        viewModel.$paneViewModels
            .receive(on: RunLoop.main)
            .sink { [weak self] panes in self?.syncPanes(panes) }
            .store(in: &cancellables)
        // Synchronous re-tile when the store applies new pane geometry, so
        // surfaces resize in the same main-actor turn.
        viewModel.onGeometryApplied = { [weak self] in self?.layoutCells() }
        // Re-bind a surface when its pane's agent was swapped in place (reset →
        // new conversation): the pane list is unchanged so `syncPanes` neither
        // tears down nor rebuilds the cell.
        viewModel.onPanesRefreshed = { [weak self] in self?.reconcilePaneRuntimes() }
        viewModel.$activePaneID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Focus mode shows exactly the active pane — switching panes
                // re-tiles (like a zoom retarget), not just the borders.
                if self.viewModel.workspaceMode == .list { self.layoutCells() }
                self.updateActiveBorders()
            }
            .store(in: &cancellables)
        viewModel.$zoomedPaneID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.layoutCells()
                self?.updateActiveBorders()   // zoom in/out → refresh focus-border suppression
            }
            .store(in: &cancellables)
        viewModel.$workspaceMode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.layoutCells()           // Tiled ⇄ Focus is a pure view change now
                self?.updateActiveBorders()
            }
            .store(in: &cancellables)

        // Voice: route the finished utterance to the active pane, and drive the
        // overlay from the controller's published state.
        voiceController.onResult = { [weak self] result in
            self?.viewModel.handleVoiceResult(result)
        }
        voiceController.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] recording in
                if recording { self?.voiceOverlay?.isHidden = false }
                else { self?.hideVoiceOverlay() }
            }
            .store(in: &cancellables)
        voiceController.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.voiceOverlay?.transcript = t }
            .store(in: &cancellables)
        voiceController.$activeDirection
            .receive(on: RunLoop.main)
            .sink { [weak self] d in self?.voiceOverlay?.direction = d }
            .store(in: &cancellables)
        voiceController.$showPreview
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                if show { self?.presentVoicePreview() } else { self?.dismissVoicePreview() }
            }
            .store(in: &cancellables)

        // Re-apply the theme to live surfaces when the user changes it in
        // Settings.
        themeObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalThemeChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reapplyTheme() }
        })
    }

    deinit {
        // Backstop for a host that never got teardown(): block observers are only
        // removed by token (removeObserver(self) doesn't touch them).
        themeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
    }

    /// Re-read the shared ThemeStore and push the theme (font size + background)
    /// to every live surface.
    private func reapplyTheme() {
        theme = ThemeStore.shared.makeCanvasTheme()
        layer?.backgroundColor = Self.bgColor(theme.background).cgColor
        for (_, cell) in cells {
            cell.surface.applyTheme(theme)
            // CGColor chrome (border + title-bar band/ink) is a static snapshot —
            // re-derive it so a light/dark flip repaints the panes, not just the
            // terminal body.
            cell.container.recolorChrome()
        }
        dividerOverlay.needsDisplay = true
        layoutCells()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// pane y=0 is the TOP row, so flip to match.
    public override var isFlipped: Bool { true }

    // MARK: - Pane lifecycle

    private func syncPanes(_ panes: [PaneViewModel]) {
        let newIDs = Set(panes.map(\.paneID))
        let torn = Set(cells.keys).subtracting(newIDs)
        let added = newIDs.subtracting(cells.keys)
        for (id, cell) in cells where !newIDs.contains(id) {
            cell.surface.teardown()
            cell.container.removeFromSuperview()
            cells[id] = nil
            // Cancel the cell's per-pane sinks with it (pure resource cleanup —
            // they all capture weak).
            cellBags.removeValue(forKey: id)
        }
        for paneVM in panes where cells[paneVM.paneID] == nil {
            cells[paneVM.paneID] = makeCell(for: paneVM)
        }
        reconcilePaneRuntimes()
        layoutCells()
        updateActiveBorders()
    }

    /// Re-attach any existing cell whose pane's live runtime no longer matches
    /// the surface's bound one. A reset (new conversation) replaces a pane's
    /// runtime in place — same pane id, same cell — so nothing here is
    /// added/torn; without this the surface keeps showing the dead old agent
    /// ("agent exited") while the fresh one runs unseen. Idempotent: attaches
    /// only on an actual identity change.
    private func reconcilePaneRuntimes() {
        for (id, cell) in cells {
            guard let current = viewModel.workspace.runtime(forPane: id.raw),
                  cell.surface.boundSession !== current else { continue }
            cell.surface.attach(current)
        }
    }

    private func makeCell(for paneVM: PaneViewModel) -> PaneCell {
        let surface = AgentChatSurface(
            session: viewModel.workspace.runtime(forPane: paneVM.paneID.raw),
            theme: theme)
        let paneID = paneVM.paneID

        wireSurfaceCallbacks(surface, paneVM: paneVM, paneID: paneID)

        let container = PaneCellView()
        wireContainerActions(container, paneVM: paneVM, paneID: paneID)
        container.embed(surface)
        // Insert BELOW the divider overlay so dividers stay hit-testable on top.
        addSubview(container, positioned: .below, relativeTo: dividerOverlay)

        wireStateBindings(paneVM: paneVM, container: container, paneID: paneID)

        return PaneCell(container: container, surface: surface)
    }

    /// Surface ↔ view-model wiring: output/input, selection, voice, split, size,
    /// and the scroll-bookmark hooks. Extracted from `makeCell`.
    /// Surface ↔ view-model wiring: selection, voice, and file preview.
    private func wireSurfaceCallbacks(_ surface: AgentChatSurface,
                                      paneVM: PaneViewModel,
                                      paneID: PaneID) {
        surface.onSelect = { [weak self] in self?.viewModel.selectPane(paneID) }
        surface.onVoicePrewarm = { [weak self] in self?.voiceController.prewarm() }
        surface.onVoiceStart = { [weak self] screenPt in self?.startVoice(forPane: paneID, atScreen: screenPt) }
        surface.onVoiceDrag = { [weak self] screenPt in self?.voiceController.update(toScreen: screenPt) }
        surface.onVoiceEnd = { [weak self] in self?.voiceController.end() }
        // Path preview (tool-card / diff path clicks): macOS panes run against
        // the local machine, so files come straight off disk. cwd = the pane's
        // live workspace path (never stale).
        surface.pathPreviewContext = PathPreviewContext(
            source: LocalFileSource(),
            cwd: { [weak paneVM, weak surface] in
                if let path = await paneVM?.currentWorkingDirectory() { return path }
                return surface?.reportedPwd
            },
            hostLabel: "This Mac",
            isLocal: true)
    }

    /// Container (title bar / chrome) action wiring. Extracted from `makeCell`.
    private func wireContainerActions(_ container: PaneCellView,
                                      paneVM: PaneViewModel,
                                      paneID: PaneID) {
        container.onClick = { [weak self] in self?.viewModel.selectPane(paneID) }
        // The pane's top-right focus button toggles the workspace mode. In
        // Parallel it enters Focus on this pane (select, then flip to List); in
        // the Focus header it's the grid button that returns to Parallel. The
        // `$workspaceMode` observers (host re-layout, toolbar segment, sidebar)
        // all follow from setMode.
        container.onFocus = { [weak self] in
            guard let self else { return }
            if self.viewModel.workspaceMode == .list {
                self.viewModel.setMode(.tiled)
            } else {
                self.viewModel.selectPane(paneID)
                self.viewModel.setMode(.list)
            }
        }
        container.onMenu = { [weak self, weak container] in
            guard let self, let container else { return }
            self.viewModel.selectPane(paneID)
            self.showPaneMenu(for: paneID, from: container.menuButtonAnchor)
        }
        container.onNewChat = { [weak self] in
            guard let self else { return }
            self.viewModel.selectPane(paneID)
            self.startNewChat(in: paneID)
        }
        container.onShowHistory = { [weak self, weak container] in
            guard let self, let container else { return }
            self.viewModel.selectPane(paneID)
            self.showHistoryMenu(for: paneID, from: container.historyButtonAnchor)
        }
        container.onPaneDrag = { [weak self] phase in
            self?.handlePaneDrag(source: paneID, phase: phase)
        }
    }

    /// Published-state → chrome bindings. The sinks live in `cellBags[paneID]`
    /// so removing the pane's cell cancels them (see `syncPanes`). Extracted
    /// from `makeCell`.
    private func wireStateBindings(paneVM: PaneViewModel,
                                   container: PaneCellView,
                                   paneID: PaneID) {
        var bag = Set<AnyCancellable>()

        // Drive the title-bar status dot from the pane's activity state.
        container.paneState = paneVM.paneState
        paneVM.$paneState
            .receive(on: RunLoop.main)
            .sink { [weak container] state in container?.paneState = state }
            .store(in: &bag)

        // "Done, unseen" badge (agent finished while you weren't looking).
        container.agentFinishedUnseen = paneVM.agentFinishedUnseen
        paneVM.$agentFinishedUnseen
            .receive(on: RunLoop.main)
            .sink { [weak container] v in container?.agentFinishedUnseen = v }
            .store(in: &bag)

        cellBags[paneID] = bag
    }

    // MARK: - Drag-to-dock (drag a pane's title bar onto another pane)
    //
    // VS Code-style drop zones: hovering a target pane previews the landing —
    // its middle 50%×50% highlights the WHOLE pane (drop = swap the two
    // panes), the four edge bands highlight that HALF (drop = re-split the
    // target along that axis and dock the dragged pane on that side).

    private var dragSourceID: PaneID?
    /// The translucent landing preview; created on the first hover of a drag,
    /// torn down when the drag ends (so theme/accent changes never go stale).
    private var dropOverlay: PaneDropZoneOverlay?

    /// The pane + drop zone under a window-coordinate point, excluding the
    /// dragged pane. nil = not over any other pane (dropping does nothing).
    private func dropTarget(at windowPoint: NSPoint, excluding source: PaneID)
        -> (pane: PaneID, zone: PaneDropZone)? {
        let local = convert(windowPoint, from: nil)
        guard let (id, cell) = cells.first(where: { id, cell in
            id != source && !cell.container.isHidden && cell.container.frame.contains(local)
        }) else { return nil }
        return (id, PaneDropZone.zone(at: local, in: cell.container.frame))
    }

    private func handlePaneDrag(source paneID: PaneID, phase: PaneDragPhase) {
        switch phase {
        case .moved(let windowPoint):
            if dragSourceID == nil {
                dragSourceID = paneID
                cells[paneID]?.container.alphaValue = 0.6
                NSCursor.closedHand.push()
            }
            updateDropOverlay(dropTarget(at: windowPoint, excluding: paneID))

        case .ended(let windowPoint):
            let drop = dropTarget(at: windowPoint, excluding: paneID)
            dropOverlay?.removeFromSuperview()
            dropOverlay = nil
            cells[paneID]?.container.alphaValue = 1.0
            if dragSourceID != nil {
                dragSourceID = nil
                NSCursor.pop()
            }
            guard let (target, zone) = drop else { return }
            if let dock = zone.dock {
                viewModel.movePane(paneID, splitting: target,
                                   horizontal: dock.horizontal, before: dock.before)
            } else {
                viewModel.swapPanes(paneID, with: target)
            }
        }
    }

    /// Show/move/hide the landing preview. The frame animates between zones
    /// and across panes while visible; appearing from hidden snaps into place
    /// so the preview never slides in from a stale spot.
    private func updateDropOverlay(_ drop: (pane: PaneID, zone: PaneDropZone)?) {
        guard let drop, let cellFrame = cells[drop.pane]?.container.frame else {
            dropOverlay?.isHidden = true
            return
        }
        let overlay: PaneDropZoneOverlay
        let appearing: Bool
        if let existing = dropOverlay {
            overlay = existing
            appearing = overlay.isHidden
        } else {
            overlay = PaneDropZoneOverlay()
            addSubview(overlay)   // above the cells and the divider overlay
            dropOverlay = overlay
            appearing = true      // a fresh overlay's frame is .zero — snap, don't slide in from the corner
        }
        let target = drop.zone.highlightRect(in: cellFrame)
        overlay.isHidden = false
        overlay.zone = drop.zone
        if appearing {
            overlay.frame = target
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                overlay.animator().frame = target
            }
        }
    }

    // MARK: - Voice (right-click-and-hold)

    /// Right-click-hold passed the threshold on `paneID`: select it, show the
    /// compass overlay at the press point, and start hold-to-talk recording.
    private func startVoice(forPane paneID: PaneID, atScreen screenPt: NSPoint) {
        viewModel.selectPane(paneID)
        showVoiceOverlay(atScreen: screenPt)
        // Feed the recording pane's on-screen text to the Qwen engine for context
        // biasing (read lazily at session start, only if the engine wants it).
        voiceController.readScreenText = { [weak self] in self?.cells[paneID]?.surface.voiceBiasContext() }
        voiceController.begin(originScreen: screenPt)
    }

    private func showVoiceOverlay(atScreen screenPt: NSPoint) {
        let overlay: MacVoiceOverlay
        if let existing = voiceOverlay {
            overlay = existing
        } else {
            overlay = MacVoiceOverlay(frame: NSRect(origin: .zero, size: MacVoiceOverlay.preferredSize))
            addSubview(overlay)   // on top of the panes + divider overlay
            voiceOverlay = overlay
        }
        overlay.transcript = ""
        overlay.direction = .none

        // Center the overlay at the press point (screen → host coords), clamped.
        let size = MacVoiceOverlay.preferredSize
        var local = NSPoint(x: bounds.midX, y: bounds.midY)
        if let window {
            local = convert(window.convertPoint(fromScreen: screenPt), from: nil)
        }
        let x = min(max(local.x - size.width / 2, 0), max(bounds.width - size.width, 0))
        let y = min(max(local.y - size.height / 2, 0), max(bounds.height - size.height, 0))
        overlay.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        overlay.isHidden = false
        overlay.needsLayout = true
    }

    private func hideVoiceOverlay() {
        voiceOverlay?.isHidden = true
    }

    /// Show the right-swipe preview as a centered, interactive overlay card over a
    /// dimmed backdrop. (A sheet would need a contentViewController; this window
    /// sets `contentView` directly, so we host the card ourselves — same approach
    /// as the recording compass.)
    private func presentVoicePreview() {
        guard voicePreview == nil else { return }
        let backdrop = NSView(frame: bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        let card = NSHostingView(rootView: MacVoicePreviewView(controller: voiceController))
        let size = NSSize(width: 480, height: 260)
        card.frame = NSRect(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height)
        card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        backdrop.addSubview(card)
        addSubview(backdrop)
        voicePreview = backdrop
        window?.makeFirstResponder(card)
    }

    private func dismissVoicePreview() {
        voicePreview?.removeFromSuperview()
        voicePreview = nil
    }

    /// Pop up a per-pane context menu (split / swap / close) anchored to the
    /// title-bar menu button. The pane is already selected, so the existing
    /// responder-chain actions operate on it.
    private func showPaneMenu(for paneID: PaneID, from anchor: NSView) {
        let menu = NSMenu()
        menu.addItem(item("Command Palette…", #selector(openCommandPalette(_:)), symbol: "command"))
        menu.addItem(item("History in This Folder…", #selector(showFolderHistory(_:)),
                          symbol: "clock.arrow.circlepath"))
        menu.addItem(.separator())
        // Splits are Tiled mode's creation path — List mode (one pane per
        // window) creates via the sidebar's New Window instead, so no split
        // entries there (the ⌘D actions below no-op the same way).
        if viewModel.workspaceMode != .list {
            // Icons make the split direction legible (the words "vertical/horizontal"
            // are ambiguous): side-by-side panes vs stacked panes. The symbol mirrors
            // the resulting layout — splitVertically → two columns, splitHorizontally
            // → two rows (matches splitPane(horizontal:) below).
            menu.addItem(item("Split Right", BentoPaneAction.splitVertically, symbol: "rectangle.split.2x1"))
            menu.addItem(item("Split Down", BentoPaneAction.splitHorizontally, symbol: "rectangle.split.1x2"))
            menu.addItem(.separator())
            // Seeded splits — creation parity with List's New Window menu (the
            // same two seeds; both split to the right).
            menu.addItem(item("Split — Duplicate Current", #selector(splitDuplicateCurrent(_:)),
                              symbol: "plus.square.on.square"))
            menu.addItem(item("Split — Path & Command…", #selector(splitWithPathCommand(_:)),
                              symbol: "terminal"))
            menu.addItem(.separator())
        }
        // Panes can also be rearranged by dragging a title bar onto
        // another pane.
        menu.addItem(item("Swap Up", BentoPaneAction.swapPaneUp, symbol: "arrow.up.square"))
        menu.addItem(item("Swap Down", BentoPaneAction.swapPaneDown, symbol: "arrow.down.square"))
        menu.addItem(.separator())
        menu.addItem(makeMoveToSessionItem())
        menu.addItem(.separator())
        menu.addItem(item("Close Pane", BentoPaneAction.closePane, symbol: "xmark"))
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.maxY),
                   in: anchor)
    }

    private func item(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        // target = self so the menu validates/dispatches directly to the host.
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        if let symbol {
            it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        return it
    }

    /// "Move to Session" submenu: other sessions on the server + "New
    /// Session…". The list is populated LAZILY via `menuNeedsUpdate` (this view
    /// is the submenu's delegate) instead of once up-front, because the fetch
    /// that warms `availableSessions` is async: building the items eagerly
    /// captured a still-cold cache, so the first open showed empty and only the
    /// second open (after the fetch landed) had sessions. Kicking the refresh
    /// when the parent menu opens + re-reading the cache when the submenu is
    /// about to display means the now-warm list appears on THIS open. Always
    /// actionable: moving the session's last pane makes the client follow the
    /// pane (see `movePane`), so no case needs disabling.
    private func makeMoveToSessionItem() -> NSMenuItem {
        Task { [viewModel] in await viewModel.refreshSessions() }
        let sub = NSMenu()
        sub.delegate = self
        moveToSessionMenu = sub
        populateMoveToSession(sub)   // initial fill; menuNeedsUpdate refreshes it
        let root = NSMenuItem(title: "Move to Workspace", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right",
                             accessibilityDescription: "Move to Workspace")
        root.submenu = sub
        return root
    }

    /// (Re)build the "Move to Session" submenu items from the current session
    /// cache. Called on initial construction and again from `menuNeedsUpdate`.
    private func populateMoveToSession(_ sub: NSMenu) {
        sub.removeAllItems()
        let others = viewModel.availableSessions
            .filter { $0 != viewModel.activeWorkspaceName }
        for name in others {
            let it = item(name, #selector(movePaneToNamedSession(_:)))
            it.representedObject = name
            sub.addItem(it)
        }
        if !others.isEmpty { sub.addItem(.separator()) }
        sub.addItem(item("New Workspace…", #selector(movePaneToNewSession(_:)), symbol: "plus"))
    }

    /// NSMenuDelegate: rebuild the "Move to Session" list right before it shows.
    /// By now the refresh kicked when the pane menu opened has (almost always)
    /// landed — its main-actor continuation runs in the tracking runloop's
    /// common modes during the human hover delay — so the freshly warmed cache
    /// is reflected on this open. Kick another refresh to keep it current for a
    /// re-open (`refreshSessions` de-dupes while one is in flight).
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === moveToSessionMenu else { return }
        Task { [viewModel] in await viewModel.refreshSessions() }
        populateMoveToSession(menu)
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        layoutCells()
    }

    /// The one pane that should fill the window alone, when any: an explicit
    /// zoom, or Focus mode (which presents exactly the active pane).
    private var soloPaneID: PaneID? {
        if let z = viewModel.zoomedPaneID { return z }
        if viewModel.workspaceMode == .list { return viewModel.activePaneID }
        return nil
    }

    /// One visible pane (single, zoomed or Focus) fills the window.
    private var isSingleOrZoom: Bool {
        soloPaneID != nil || viewModel.paneViewModels.count <= 1
    }

    /// The bounding box of all panes in session cell units (used as the tiling grid).
    var paneGridSize: (cols: CGFloat, rows: CGFloat) {
        let panes = viewModel.paneViewModels
        let cols = CGFloat(max(panes.map { $0.pane.x + $0.pane.width }.max() ?? 1, 1))
        let rows = CGFloat(max(panes.map { $0.pane.y + $0.pane.height }.max() ?? 1, 1))
        return (cols, rows)
    }

    /// Tile panes proportionally to fill the host: each pane's frame is its
    /// layout-tree fraction × the host bounds (recovered from the legacy
    /// 160×48 projection the store still publishes). When a pane is zoomed,
    /// it alone fills the host and the rest are hidden (iTerm2 zoom).
    private func layoutCells() {
        let panes = viewModel.paneViewModels
        guard !panes.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        // One lookup table instead of a linear scan per cell (×2 loops below).
        let vmByID = Dictionary(panes.map { ($0.paneID, $0) }, uniquingKeysWith: { a, _ in a })
        // Focus mode: the single pane gets a roomier header (title + state +
        // the pane-scoped controls: new-chat, history, back-to-Parallel, ⋯) so
        // those actions live on the pane you're reading, not only the sidebar.
        let focusMode = viewModel.workspaceMode == .list
        let titleBar = focusMode ? Self.focusHeaderHeight : Self.fallbackTitleBarHeight

        for (_, cell) in cells {
            cell.container.isFocusHeader = focusMode
            cell.container.titleBarHeight = titleBar
            // The chat adopts its roomier reading layout in Focus mode.
            cell.surface.setFocusMode(focusMode)
        }

        // Zoomed / Focus / single pane: one surface fills the window.
        if let solo = soloPaneID, cells[solo] != nil {
            for (id, cell) in cells {
                let isZoom = (id == solo)
                cell.container.isHidden = !isZoom
                if isZoom {
                    // The solo cell isn't hit by the per-pane title pass below,
                    // so refresh its header title here (name follows the active
                    // pane as Focus retargets).
                    if let vm = vmByID[id] { cell.container.title = paneTitle(for: vm) }
                    cell.container.surfaceInsetX = 0
                    cell.container.frame = bounds
                }
            }
            dividerOverlay.refresh()
            return
        }

        let grid = paneGridSize
        let fx = bounds.width / grid.cols
        let fy = bounds.height / grid.rows
        for (id, cell) in cells {
            guard let paneVM = vmByID[id] else { continue }
            let p = paneVM.pane
            cell.container.isHidden = false
            cell.container.title = paneTitle(for: paneVM)

            if panes.count == 1 {
                // Single pane: fill the window.
                cell.container.surfaceInsetX = 0
                cell.container.frame = bounds
            } else {
                // Proportional layout: the pane's fraction of the canvas maps
                // straight onto the host bounds. Neighbors share exact edges
                // (the projection rounds edges, not sizes); the title bar sits
                // at the top of each pane's own frame, and surfaceInsetX keeps
                // a hairline gutter between side-by-side surfaces.
                cell.container.surfaceInsetX = Self.paneGutter
                cell.container.frame = NSRect(
                    x: CGFloat(p.x) * fx,
                    y: CGFloat(p.y) * fy,
                    width: CGFloat(p.width) * fx,
                    height: CGFloat(p.height) * fy)
            }
        }
        dividerOverlay.refresh()
    }

    private func paneTitle(for paneVM: PaneViewModel) -> String {
        let p = paneVM.pane
        let cmd = p.currentCommand?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = p.title?.trimmingCharacters(in: .whitespaces) ?? ""
        if !title.isEmpty, title != cmd { return cmd.isEmpty ? title : "\(cmd) — \(title)" }
        return cmd.isEmpty ? "agent" : cmd
    }

    private func updateActiveBorders() {
        let active = viewModel.activePaneID
        let suppress = isSingleOrZoom   // one visible pane → nothing to disambiguate
        for (id, cell) in cells {
            cell.container.focusSuppressed = suppress
            cell.container.isActivePane = (id == active)
            // Only steal first responder when it actually needs to change. An
            // unconditional makeFirstResponder re-activates the surface's
            // NSTextInputContext every call, which churns the macOS text-input
            // stack (utTryToSetupInputMethodMenu + per-activation IMK/TSM XPC
            // connections). Profiling showed that churn stalling keystrokes and
            // the XPC connections accumulating over a session ("slower over time").
            // A first responder INSIDE the surface (the chat composer's field
            // editor) counts as the surface having focus — yanking it back
            // would fight the composer for every keystroke.
            if id == active, window?.firstResponder !== cell.surface,
               !((window?.firstResponder as? NSView)?.isDescendant(of: cell.surface) ?? false) {
                window?.makeFirstResponder(cell.surface)
            }
        }
    }

    // MARK: - Pane geometry queries (used by the divider overlay)

    /// All current cell frames keyed by pane id.
    var cellFrames: [(id: PaneID, frame: NSRect)] {
        cells.compactMap { id, cell in
            cell.container.isHidden ? nil : (id, cell.container.frame)
        }
    }

    /// Resize the boundary owned by `paneID` along an axis by a signed cell delta.
    /// Vertical divider → grow/shrink to the Right/Left; horizontal → Down/Up.
    func resizeBoundary(paneID: PaneID, vertical: Bool, deltaCells: Int) {
        guard deltaCells != 0 else { return }
        let dir: String
        if vertical {
            dir = deltaCells > 0 ? "R" : "L"
        } else {
            dir = deltaCells > 0 ? "D" : "U"
        }
        viewModel.resizePaneBy(paneID, direction: dir, amount: abs(deltaCells))
    }

    // MARK: - Menu / keyboard actions (reached via the responder chain)

    private var activePaneID: PaneID? { viewModel.activePaneID }

    /// Panes ordered top-to-bottom, left-to-right for stable navigation.
    private var orderedPaneIDs: [PaneID] {
        viewModel.paneViewModels
            .sorted { ($0.pane.y, $0.pane.x) < ($1.pane.y, $1.pane.x) }
            .map(\.paneID)
    }

    /// Splits only exist in Tiled mode — List keeps one pane per window, so
    /// ⌘D/⌘⇧D (and the pane-menu split items, hidden there) are no-ops.
    private var splitsAllowed: Bool { viewModel.workspaceMode != .list }

    @objc public func splitPaneVertically(_ sender: Any?) {
        guard splitsAllowed else { return }
        // iTerm2 "Split Vertically" = side-by-side panes (a vertical divider).
        viewModel.splitPane(horizontal: true)
    }

    @objc public func splitPaneHorizontally(_ sender: Any?) {
        guard splitsAllowed else { return }
        // iTerm2 "Split Horizontally" = stacked panes (a horizontal divider).
        viewModel.splitPane(horizontal: false)
    }

    /// Split seeded like List's "Duplicate Current": same working directory and
    /// start command as the active pane (which the menu just selected).
    @objc func splitDuplicateCurrent(_ sender: Any?) {
        guard splitsAllowed else { return }
        Task { [viewModel] in await viewModel.splitPane(horizontal: true, seed: .duplicateCurrent) }
    }

    /// Split seeded with an explicit directory and command — the dialog itself
    /// is a native directory chooser (with a command popup baked in), seeded at
    /// the active pane's cwd. Same picker as List's New Window.
    @objc func splitWithPathCommand(_ sender: Any?) {
        guard splitsAllowed else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cwd = await self.viewModel.activePaneWorkingDirectory()
            presentNewPaneDirectoryPanel(
                title: "Split", prompt: "Split", initialDirectory: cwd,
                onCreate: { [viewModel = self.viewModel] path, command in
                    Task { await viewModel.splitPane(horizontal: true, seed: .custom(path: path, command: command)) }
                },
                onResume: { [weak self] entry in
                    // A folder with history offers "continue" — reopen the
                    // recorded conversation instead of spawning a fresh agent.
                    self?.openHistoryEntry(entry)
                })
        }
    }

    // MARK: - Command palette (⌘P)

    /// Open the command palette over this window's focused pane: its file
    /// context (source + cwd) drives the File section; the Command / New Pane /
    /// Recent sections are wired to this host.
    func presentCommandPalette() {
        let ctx = activePaneID.flatMap { cells[$0]?.surface.pathPreviewContext }
        CommandPaletteController.shared.present(
            fileContext: ctx,
            hostLabel: ctx?.hostLabel ?? "This Mac",
            staticSpecs: buildPaletteSpecs())
    }

    @objc private func openCommandPalette(_ sender: Any?) { presentCommandPalette() }

    /// The focused pane's file context — the dock's tree roots itself here.
    var activePathPreviewContext: PathPreviewContext? {
        activePaneID.flatMap { cells[$0]?.surface.pathPreviewContext }
    }

    private func buildPaletteSpecs() -> [PaletteSectionSpec] {
        var specs: [PaletteSectionSpec] = []

        // Recent files — empty-state suggestions (once you type, the live File
        // section covers them).
        let recentFiles = PaletteRecents.shared.files.map { entry in
            PaletteItem(id: "recent:" + entry.path,
                        title: (entry.path as NSString).lastPathComponent,
                        subtitle: paletteAbbrev(entry.path),
                        systemImage: "clock",
                        matchText: (entry.path as NSString).lastPathComponent,
                        action: .preview(path: entry.path, line: nil))
        }
        if !recentFiles.isEmpty {
            specs.append(PaletteSectionSpec(id: "recentFiles", title: "Recent Files",
                                            items: recentFiles, emptyStateOnly: true, limit: 5))
        }

        // New pane: recent (directory + command) launches → spawn a pane there.
        let launches = PaletteRecents.shared.launches.map { l -> PaletteItem in
            let name = l.command.isEmpty ? "shell" : l.command
            return PaletteItem(id: "launch:\(l.dir)::\(l.command)",
                               title: "\(name)  ·  \(paletteAbbrev(l.dir))",
                               systemImage: "plus.rectangle.on.rectangle",
                               matchText: "\(name) \(l.dir)",
                               action: .run { [weak self] in self?.launchPane(dir: l.dir, command: l.command) })
        }
        if !launches.isEmpty {
            specs.append(PaletteSectionSpec(id: "launches", title: "New Pane", items: launches, limit: 6))
        }

        // History: past conversations, reopenable in place. matchText carries
        // the cwd so a path fragment ("api", "proj/web") filters history too.
        let liveIDs = AgentWorkspaceStore.shared.liveSessionIDs
        let history = AgentWorkspaceStore.shared.catalogEntries()
            .filter { !$0.expired }
            .prefix(20)
            .map { entry -> PaletteItem in
                let live = liveIDs.contains(entry.acpSessionID)
                let title = entry.title.isEmpty ? "Untitled" : entry.title
                return PaletteItem(
                    id: "history:" + entry.acpSessionID,
                    title: live ? title + "  ·  live" : title,
                    subtitle: "\(SessionHistoryModel.agentName(entry.presetID))  ·  \(paletteAbbrev(entry.cwd))",
                    systemImage: live ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath",
                    matchText: "\(title) \(entry.cwd)",
                    action: .run { [weak self] in self?.openHistoryEntry(entry) })
            }
        if !history.isEmpty {
            specs.append(PaletteSectionSpec(id: "history", title: "History",
                                            items: Array(history), limit: 6))
        }

        specs.append(PaletteSectionSpec(id: "commands", title: "Commands",
                                        items: paletteCommands(), limit: 10))
        return specs
    }

    /// History (pane button / palette / folder / panel): reopen the conversation
    /// IN THE CURRENT PANE — reuse it rather than splitting a new pane. A
    /// session already live elsewhere is focused in place by the store (never
    /// two panes on one ACP session).
    private func openHistoryEntry(_ entry: CatalogEntry) {
        guard let active = viewModel.activePaneID else { return }
        AgentWorkspaceStore.shared.openHistorySession(entry, inPane: active.raw)
    }

    /// Pane menu → History in This Folder: the history panel pre-filtered
    /// to this pane's working directory (subtree). The menu already selected
    /// the pane, so activePaneID is the one whose folder scopes the list.
    @objc private func showFolderHistory(_ sender: Any?) {
        let cwd = activePaneID.flatMap { viewModel.workspace.paneCwd($0.raw) }
        SessionHistoryPanelController.shared.present(
            store: .shared, initialDirectory: cwd
        ) { [weak self] entry in
            self?.openHistoryEntry(entry)
        }
    }

    /// Title-bar new-chat button: drop the current conversation (it lives on
    /// in history) and spawn a fresh agent in the same pane — same preset,
    /// same cwd, no resume. The pane stays in place; only its session turns
    /// over.
    private func startNewChat(in paneID: PaneID) {
        viewModel.workspace.resetPane(paneID.raw)
    }

    /// Title-bar history button: a lightweight NSMenu of recent catalog
    /// entries (vs the heavier floating panel). Picking one reopens the
    /// conversation in place; the trailing items fall through to the panel
    /// for search/filter when the list is too long to scan by eye.
    private func showHistoryMenu(for paneID: PaneID, from anchor: NSView) {
        let store = AgentWorkspaceStore.shared
        let liveIDs = store.liveSessionIDs
        let cwd = store.paneCwd(paneID.raw)
        // Folder-scoped entries first (most likely what the user wants when
        // they're in this pane), then a separator + the unscoped recent tail.
        var entries: [CatalogEntry] = []
        var seenIDs = Set<String>()
        if let cwd {
            for entry in store.catalogEntries(cwd: cwd, subtree: true)
                .filter({ !$0.expired }) where !seenIDs.contains(entry.acpSessionID) {
                entries.append(entry); seenIDs.insert(entry.acpSessionID)
            }
        }
        let folderScoped = entries.count
        for entry in store.catalogEntries()
            .filter({ !$0.expired }) where !seenIDs.contains(entry.acpSessionID) {
            entries.append(entry); seenIDs.insert(entry.acpSessionID)
        }
        let displayLimit = 15
        let menu = NSMenu()
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No Conversations", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, entry) in entries.prefix(displayLimit).enumerated() {
                let live = liveIDs.contains(entry.acpSessionID)
                let title = entry.title.isEmpty ? "Untitled" : entry.title
                let subtitle = "\(SessionHistoryModel.agentName(entry.presetID))  ·  \(Self.historyAbbrev(entry.cwd))  ·  \(SessionHistoryView.relativeTime(entry.lastActive))"
                let item = NSMenuItem(title: title, action: #selector(historyMenuOpen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry
                item.toolTip = subtitle
                item.image = NSImage(systemSymbolName: live
                                     ? "dot.radiowaves.left.and.right"
                                     : "clock.arrow.circlepath",
                                     accessibilityDescription: nil)
                if index == folderScoped, folderScoped > 0 {
                    menu.addItem(.separator())
                }
                menu.addItem(item)
            }
            if entries.count > displayLimit {
                menu.addItem(.separator())
                let more = NSMenuItem(title: "All History…", action: #selector(showAllHistory(_:)),
                                      keyEquivalent: "")
                more.target = self
                more.image = NSImage(systemSymbolName: "magnifyingglass",
                                     accessibilityDescription: nil)
                menu.addItem(more)
            }
        }
        menu.addItem(.separator())
        let inFolder = NSMenuItem(title: "History in This Folder…",
                                  action: #selector(showFolderHistory(_:)), keyEquivalent: "")
        inFolder.target = self
        inFolder.image = NSImage(systemSymbolName: "folder",
                                 accessibilityDescription: nil)
        menu.addItem(inFolder)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.maxY),
                   in: anchor)
    }

    @objc private func historyMenuOpen(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let entry = item.representedObject as? CatalogEntry else { return }
        openHistoryEntry(entry)
    }

    @objc private func showAllHistory(_ sender: Any?) {
        SessionHistoryPanelController.shared.present(store: .shared) { [weak self] entry in
            self?.openHistoryEntry(entry)
        }
    }

    /// Abbreviate a cwd path for menu tooltips (last 2 path components).
    private static func historyAbbrev(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    private func paletteCommands() -> [PaletteItem] {
        func cmd(_ id: String, _ title: String, _ image: String,
                 _ run: @escaping @MainActor () -> Void) -> PaletteItem {
            PaletteItem(id: "cmd:" + id, title: title, systemImage: image,
                        matchText: title, action: .run(run))
        }
        return [
            cmd("splitRight", "Split Pane Right", "rectangle.split.2x1") { [weak self] in self?.splitPaneVertically(nil) },
            cmd("splitDown", "Split Pane Down", "rectangle.split.1x2") { [weak self] in self?.splitPaneHorizontally(nil) },
            cmd("duplicate", "Duplicate Pane (dir + command)", "plus.square.on.square") { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.splitPane(horizontal: true, seed: .duplicateCurrent) }
            },
            cmd("closePane", "Close Pane", "xmark.square") { [weak self] in self?.closeCurrentPane(nil) },
            cmd("focus", "Focus Current Pane", "rectangle.inset.filled") { [weak self] in self?.viewModel.setMode(.list) },
            cmd("nextPane", "Select Next Pane", "arrow.right.square") { [weak self] in self?.selectNextPane(nil) },
            cmd("prevPane", "Select Previous Pane", "arrow.left.square") { [weak self] in self?.selectPreviousPane(nil) },
            cmd("newPaneAction", "New Pane", "plus.rectangle.on.folder") { [weak self] in self?.newPaneAction(nil) },
            cmd("newWindow", "New Workspace Window", "macwindow.badge.plus") { WorkspaceWindow.newWindow() },
            cmd("toggleDock", "Toggle Preview Panel", "sidebar.trailing") { WorkspaceWindow.togglePreviewDock() },
        ]
    }

    /// Spawn a pane in `dir` running `command` (empty = plain shell), over the
    /// already-attached control channel (no pty typed-ahead race), and remember
    /// it for the palette's New Pane suggestions.
    private func launchPane(dir: String, command: String) {
        let cmd = command.isEmpty ? nil : command
        Task { [viewModel] in
            await viewModel.splitPane(horizontal: true, seed: .custom(path: dir, command: cmd))
        }
        PaletteRecents.shared.recordLaunch(dir: dir, command: command)
    }

    private func paletteAbbrev(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Pane menu → Move to Session → <name>. The menu already selected the
    /// pane, so activePaneID is the one to move (same convention as the other
    /// pane actions). The pane keeps running; where it lands follows the
    /// target's mode (Parallel → its current window, Focus → a new window),
    /// and an unsettled target asks via `promptMoveLanding`.
    @objc func movePaneToNamedSession(_ sender: Any?) {
        guard let active = activePaneID,
              let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        moveActivePane(active, to: name)
    }

    private func moveActivePane(_ pane: PaneID, to name: String) {
        Task { [weak self] in
            _ = await self?.viewModel.movePane(pane, toSession: name)
        }
    }

    /// Pane menu → Move to Session → New Session…: prompt for a name, then
    /// the same move path (movePane creates the session when it's missing).
    @objc func movePaneToNewSession(_ sender: Any?) {
        guard let window, let active = activePaneID else { return }
        let alert = NSAlert()
        alert.messageText = "Move Pane to New Workspace"
        alert.informativeText = "The pane keeps running — it moves to the new workspace."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Workspace name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.moveActivePane(active, to: field.stringValue)
        }
    }

    @objc public func closeCurrentPane(_ sender: Any?) {
        guard let active = activePaneID else { return }
        viewModel.closePane(active)
    }

    /// Flip the workspace to Focus (List) mode on the current pane. Replaces the
    /// old per-pane zoom; Focus already presents exactly the active pane.
    @objc public func focusCurrentPane(_ sender: Any?) {
        viewModel.setMode(.list)
    }

    @objc public func swapActivePaneUp(_ sender: Any?) {
        guard let active = activePaneID else { return }
        viewModel.swapPane(active, up: true)
    }

    @objc public func swapActivePaneDown(_ sender: Any?) {
        guard let active = activePaneID else { return }
        viewModel.swapPane(active, up: false)
    }

    @objc public func selectNextPane(_ sender: Any?) {
        cyclePane(by: 1)
    }

    @objc public func selectPreviousPane(_ sender: Any?) {
        cyclePane(by: -1)
    }

    @objc public func newSessionWindow(_ sender: Any?) {
        WorkspaceWindow.newWindow()
    }

    /// ⌘1..⌘9: select the Nth pane (1-based) in layout order. No-op if
    /// there's no pane at that ordinal.
    private func selectPane(ordinal n: Int) {
        let ids = orderedPaneIDs
        guard n >= 1, n <= ids.count else { return }
        viewModel.selectPane(ids[n - 1])
    }

    @objc public func selectPane1(_ sender: Any?) { selectPane(ordinal: 1) }
    @objc public func selectPane2(_ sender: Any?) { selectPane(ordinal: 2) }
    @objc public func selectPane3(_ sender: Any?) { selectPane(ordinal: 3) }
    @objc public func selectPane4(_ sender: Any?) { selectPane(ordinal: 4) }
    @objc public func selectPane5(_ sender: Any?) { selectPane(ordinal: 5) }
    @objc public func selectPane6(_ sender: Any?) { selectPane(ordinal: 6) }
    @objc public func selectPane7(_ sender: Any?) { selectPane(ordinal: 7) }
    @objc public func selectPane8(_ sender: Any?) { selectPane(ordinal: 8) }
    @objc public func selectPane9(_ sender: Any?) { selectPane(ordinal: 9) }

    /// New pane (⌃⌘T), dispatched by mode: in List it's THE creation
    /// action — a new pane seeded from the current one (same as the
    /// sidebar's "Duplicate Current"); in Tiled it opens a fresh default
    /// pane (largest-cell insertion).
    @objc public func newPaneAction(_ sender: Any?) {
        if viewModel.workspaceMode == .list {
            Task { [viewModel] in await viewModel.newFocusPane(.duplicateCurrent) }
        } else {
            viewModel.newPane()
        }
    }

    private func cyclePane(by step: Int) {
        let ids = orderedPaneIDs
        guard !ids.isEmpty else { return }
        let current = activePaneID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = ((current + step) % ids.count + ids.count) % ids.count
        viewModel.selectPane(ids[next])
    }
}

/// Selectors for the pane actions above, so SwiftUI `.commands` (or any menu)
/// can dispatch them through the responder chain to the focused host. SwiftUI
/// owns `NSApp.mainMenu` in a `MenuBarExtra` app, so we declare the menu with
/// `.commands` and route each command here rather than installing an NSMenu.
public enum BentoPaneAction {
    public static let splitVertically = #selector(TiledPaneHost.splitPaneVertically(_:))
    public static let splitHorizontally = #selector(TiledPaneHost.splitPaneHorizontally(_:))
    public static let closePane = #selector(TiledPaneHost.closeCurrentPane(_:))
    public static let focusPane = #selector(TiledPaneHost.focusCurrentPane(_:))
    public static let swapPaneUp = #selector(TiledPaneHost.swapActivePaneUp(_:))
    public static let swapPaneDown = #selector(TiledPaneHost.swapActivePaneDown(_:))
    public static let nextPane = #selector(TiledPaneHost.selectNextPane(_:))
    public static let previousPane = #selector(TiledPaneHost.selectPreviousPane(_:))
    public static let newWindow = #selector(TiledPaneHost.newSessionWindow(_:))
    /// New pane in the current session.
    public static let newPane = #selector(TiledPaneHost.newPaneAction(_:))

    /// ⌘1..⌘9 → switch to the Nth pane (1-based). Index 0 = ⌘1.
    public static let selectPane: [Selector] = [
        #selector(TiledPaneHost.selectPane1(_:)),
        #selector(TiledPaneHost.selectPane2(_:)),
        #selector(TiledPaneHost.selectPane3(_:)),
        #selector(TiledPaneHost.selectPane4(_:)),
        #selector(TiledPaneHost.selectPane5(_:)),
        #selector(TiledPaneHost.selectPane6(_:)),
        #selector(TiledPaneHost.selectPane7(_:)),
        #selector(TiledPaneHost.selectPane8(_:)),
        #selector(TiledPaneHost.selectPane9(_:)),
    ]

    /// Dispatch an action through the responder chain (nil target → focused host).
    @MainActor public static func dispatch(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

private struct PaneCell {
    let container: PaneCellView
    let surface: AgentChatSurface
}
#endif
