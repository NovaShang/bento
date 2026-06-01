#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftTmux

/// iTerm2-style TILED multi-pane host for macOS. Every tmux pane is shown at
/// once, laid out by its tmux cell geometry (x/y/width/height), each in its own
/// GhosttyTerminalSurface fed by its PaneViewModel. The window's pixel size is
/// converted (via the font cell size) to a tmux client cols×rows; tmux owns the
/// split layout and we mirror it.
///
/// iTerm2-parity features:
///   - per-pane title bar (command + title), accent-highlighted when active
///   - click a pane to focus it; active pane gets an accent border
///   - zoom (⌘⇧Return): the zoomed pane fills the window, others hidden
///   - drag the divider between adjacent panes to resize (sends `resize-pane`)
///   - menu / keyboard split, close, and next/prev-pane navigation
@MainActor
public final class GhosttyTiledPaneHost: NSView {
    let viewModel: TerminalViewModel
    private var theme: TerminalTheme
    private var cells: [TmuxPaneID: PaneCell] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Cell size in pixels (constant for the font); learned from the first surface.
    private var cellPx: CGSize?
    private var resizeDebounce: DispatchWorkItem?
    private var lastClient: (cols: Int, rows: Int)?
    private let dividerOverlay = DividerOverlay()

    /// Tear down every pane's ghostty surface (display link + surface free) on
    /// the main thread before the window/view hierarchy is released — see
    /// GhosttyTerminalSurface.teardown(). Call from windowWillClose.
    public func teardown() {
        cancellables.removeAll()
        for (_, cell) in cells { cell.surface.teardown() }
    }

    /// Height (points) of each pane's title strip. Reserved out of the terminal
    /// area so the tmux client size we report matches the visible grid.
    static let titleBarHeight: CGFloat = 20

    public init(viewModel: TerminalViewModel, theme: TerminalTheme) {
        self.viewModel = viewModel
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).cgColor

        dividerOverlay.host = self
        dividerOverlay.autoresizingMask = [.width, .height]
        addSubview(dividerOverlay)

        viewModel.$paneViewModels
            .receive(on: RunLoop.main)
            .sink { [weak self] panes in self?.syncPanes(panes) }
            .store(in: &cancellables)
        viewModel.$activePaneID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateActiveBorders() }
            .store(in: &cancellables)
        viewModel.$zoomedPaneID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutCells() }
            .store(in: &cancellables)

        // Re-apply theme/font to live surfaces when the user changes them in
        // Settings. (Colors are app-wide via GhosttyRuntime's config; this picks
        // up the font size — applyTheme recreates the surface on a size change —
        // and the surrounding background.)
        for name in [Notification.Name.terminalThemeChanged, .terminalFontChanged] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reapplyTheme() }
            }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Re-read the shared ThemeStore and push the theme (font size + background)
    /// to every live surface.
    private func reapplyTheme() {
        theme = ThemeStore.shared.makeTerminalTheme()
        layer?.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).cgColor
        // A font change (size OR family) changes the pixel size of one cell, so
        // the cached cell metrics and last-pushed tmux client size are now stale.
        // Drop them: the next surface size report re-learns cellPx (the `cellPx
        // == nil` branch in onSizeChanged) and re-pushes the client size, then we
        // re-tile against the new grid. Without this the surfaces stay sized to
        // the old font's cells and the layout tears.
        cellPx = nil
        lastClient = nil
        for (_, cell) in cells { cell.surface.applyTheme(theme) }
        layoutCells()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// tmux pane y=0 is the TOP row, so flip to match.
    public override var isFlipped: Bool { true }

    // MARK: - Pane lifecycle

    private func syncPanes(_ panes: [PaneViewModel]) {
        let newIDs = Set(panes.map(\.paneID))
        for (id, cell) in cells where !newIDs.contains(id) {
            cell.container.removeFromSuperview()
            cells[id] = nil
        }
        for paneVM in panes where cells[paneVM.paneID] == nil {
            cells[paneVM.paneID] = makeCell(for: paneVM)
        }
        layoutCells()
        updateActiveBorders()
    }

    private func makeCell(for paneVM: PaneViewModel) -> PaneCell {
        let surface = GhosttyTerminalSurface(theme: theme)
        let paneID = paneVM.paneID

        paneVM.onDataReceived = { [weak surface] data in
            DispatchQueue.main.async { surface?.feed(data) }
        }
        surface.onInput = { [weak paneVM] data in paneVM?.sendInput(data) }
        surface.onSelect = { [weak self] in self?.viewModel.selectPane(paneID) }
        surface.onSplit = { [weak self] horizontal in
            self?.viewModel.selectPane(paneID)
            self?.viewModel.splitPane(horizontal: horizontal)
        }
        surface.onSizeChanged = { [weak self] size in
            guard let self else { return }
            if self.cellPx == nil, size.cellWidthPx > 0, size.cellHeightPx > 0 {
                self.cellPx = CGSize(width: size.cellWidthPx, height: size.cellHeightPx)
                self.recomputeClientSize()
                self.layoutCells()
            }
            // Single / zoomed pane: this surface fills the window, so ghostty's
            // reported grid IS exactly what's rendered — drive the tmux client
            // size from it (authoritative). Using the host's bounds math instead
            // drifts by ~1 cell vs ghostty's internal padding, which made the
            // shell wrap/redraw at the wrong width (double-echoed commands, prompt
            // pinned to the bottom, big vertical gaps).
            if self.isSingleOrZoom, self.isVisiblePane(paneID) {
                self.pushAuthoritativeClientSize(cols: size.columns, rows: size.rows)
            }
        }

        let container = PaneCellView()
        container.onClick = { [weak self] in self?.viewModel.selectPane(paneID) }
        container.onZoom = { [weak self] in
            self?.viewModel.selectPane(paneID)
            self?.viewModel.toggleZoom(paneID)
        }
        container.onMenu = { [weak self, weak container] in
            guard let self, let container else { return }
            self.viewModel.selectPane(paneID)
            self.showPaneMenu(for: paneID, from: container.menuButtonAnchor)
        }
        container.embed(surface)
        // Insert BELOW the divider overlay so dividers stay hit-testable on top.
        addSubview(container, positioned: .below, relativeTo: dividerOverlay)

        // Drive the title-bar status dot from the pane's detected state (reuses
        // the shared StateDetectionService via PaneViewModel.paneState).
        container.paneState = paneVM.paneState
        paneVM.$paneState
            .receive(on: RunLoop.main)
            .sink { [weak container] state in container?.paneState = state }
            .store(in: &cancellables)

        return PaneCell(container: container, surface: surface)
    }

    /// Pop up a per-pane context menu (split / zoom / close) anchored to the
    /// title-bar menu button. The pane is already selected, so the existing
    /// responder-chain actions operate on it.
    private func showPaneMenu(for paneID: TmuxPaneID, from anchor: NSView) {
        let menu = NSMenu()
        let zoomTitle = (viewModel.zoomedPaneID == paneID) ? "Unzoom" : "Zoom"
        menu.addItem(item("Split Vertically", BentoPaneAction.splitVertically))
        menu.addItem(item("Split Horizontally", BentoPaneAction.splitHorizontally))
        menu.addItem(.separator())
        menu.addItem(item(zoomTitle, BentoPaneAction.toggleZoom))
        menu.addItem(.separator())
        menu.addItem(item("Close Pane", BentoPaneAction.closePane))
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.maxY),
                   in: anchor)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        // target = self so the menu validates/dispatches directly to the host.
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        recomputeClientSize()
        layoutCells()
    }

    private var currentScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    /// Distinct vertical levels = stacked title bars sharing the window height.
    private var verticalLevels: Int {
        max(Set(viewModel.paneViewModels.map { $0.pane.y }).count, 1)
    }

    /// One visible pane (single or zoomed) fills the window, so its surface's
    /// reported grid is authoritative and drives tmux directly — see
    /// `pushAuthoritativeClientSize`. Only the multi-pane TILED case needs the
    /// window-bounds estimate below.
    private var isSingleOrZoom: Bool {
        viewModel.zoomedPaneID != nil || viewModel.paneViewModels.count <= 1
    }

    /// Whether `paneID` is the currently visible pane (zoomed one, or the sole pane).
    private func isVisiblePane(_ paneID: TmuxPaneID) -> Bool {
        if let z = viewModel.zoomedPaneID { return z == paneID }
        return true   // single pane
    }

    private var didInitialScreenClean = false

    /// Push ghostty's authoritative reported grid as the tmux client size
    /// (deduped + debounced). Exact match → no wrap/redraw artifacts.
    private func pushAuthoritativeClientSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard lastClient?.cols != cols || lastClient?.rows != rows else { return }
        lastClient = (cols, rows)
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.viewModel.resizeTmuxClient(cols: cols, rows: rows)
            // One-shot after the first (attach) resize: the pty/tmux started at
            // a default size, drew the prompt, then we resized to the window's
            // real grid — leaving a stale pre-resize prompt + blank gap. A single
            // Ctrl-L makes zsh repaint the prompt cleanly at the top (scrollback
            // preserved; in a TUI it's a harmless redraw).
            if !self.didInitialScreenClean {
                self.didInitialScreenClean = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                    self?.viewModel.sendData(Data([0x0C]))
                }
            }
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Convert the window pixel size → tmux client cols×rows and push it (debounced).
    /// Title-bar space is subtracted so the reported grid matches what's visible.
    /// Only used for the multi-pane tiled case; single/zoomed panes drive tmux
    /// from the authoritative surface grid instead.
    private func recomputeClientSize() {
        guard !isSingleOrZoom else { return }
        guard let cellPx, bounds.width > 0, bounds.height > 0 else { return }
        let scale = currentScale
        let usableHeight = bounds.height - Self.titleBarHeight * CGFloat(verticalLevels)
        let cols = max(Int((bounds.width * scale) / cellPx.width), 2)
        let rows = max(Int((usableHeight * scale) / cellPx.height), 1)
        guard lastClient?.cols != cols || lastClient?.rows != rows else { return }
        lastClient = (cols, rows)
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.viewModel.resizeTmuxClient(cols: cols, rows: rows)
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// The bounding box of all panes in tmux cell units (used as the tiling grid).
    var paneGridSize: (cols: CGFloat, rows: CGFloat) {
        let panes = viewModel.paneViewModels
        let cols = CGFloat(max(panes.map { $0.pane.x + $0.pane.width }.max() ?? 1, 1))
        let rows = CGFloat(max(panes.map { $0.pane.y + $0.pane.height }.max() ?? 1, 1))
        return (cols, rows)
    }

    /// Points per tmux cell (font cell size ÷ backing scale), or nil until the
    /// cell size has been learned from a surface.
    private var pointsPerCell: CGSize? {
        guard let cellPx else { return nil }
        let scale = currentScale
        return CGSize(width: cellPx.width / scale, height: cellPx.height / scale)
    }

    /// Tile panes proportionally to fill the host, using the bounding box of all
    /// panes as the cell grid. When a pane is zoomed, it alone fills the host and
    /// the rest are hidden (iTerm2 zoom).
    ///
    /// The *container* is positioned proportionally (so panes always fill the
    /// window), but each terminal *surface* is sized to its EXACT tmux cell
    /// dimensions (cols×rows × cell px). That guarantees ghostty's own grid
    /// equals the grid tmux assigned the pane — otherwise a TUI sized by tmux to
    /// N columns would be rendered into a surface ghostty thinks is N±1 wide, and
    /// the layout tears. Sizing from tmux geometry (not window proportions) also
    /// removes the resize-timing races: the surface only changes when tmux's pane
    /// size actually changes.
    private func layoutCells() {
        let panes = viewModel.paneViewModels
        guard !panes.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let ppc = pointsPerCell

        if let zoomed = viewModel.zoomedPaneID, cells[zoomed] != nil {
            for (id, cell) in cells {
                let isZoom = (id == zoomed)
                cell.container.isHidden = !isZoom
                if isZoom {
                    cell.container.frame = bounds
                    // Fill: a single visible surface drives tmux from its own
                    // reported grid (authoritative), so no cell-exact fudge.
                    cell.container.terminalCellSize = nil
                }
            }
            dividerOverlay.refresh()
            return
        }

        // Single pane: fill the window and let its surface drive tmux from the
        // authoritative reported grid (no cell-exact fudge). Only true multi-pane
        // tiling needs the cell-exact sizing so each pane's grid matches tmux.
        let singlePane = panes.count == 1
        let (totalCols, totalRows) = paneGridSize
        let W = bounds.width, H = bounds.height
        for (id, cell) in cells {
            guard let paneVM = panes.first(where: { $0.paneID == id }) else { continue }
            let p = paneVM.pane
            cell.container.isHidden = false
            cell.container.frame = NSRect(
                x: (CGFloat(p.x) / totalCols) * W,
                y: (CGFloat(p.y) / totalRows) * H,
                width: (CGFloat(p.width) / totalCols) * W,
                height: (CGFloat(p.height) / totalRows) * H
            )
            cell.container.terminalCellSize = singlePane ? nil : ppc.map { exactSurfaceSize(p, $0) }
            cell.container.title = paneTitle(for: paneVM)
        }
        dividerOverlay.refresh()
    }

    /// The surface pixel size (points) for a pane. We add ONE extra cell in each
    /// axis: ghostty derives its grid as `floor((px − window_padding)/cell)`, so
    /// sizing to exactly cols×cell yields cols−1 (a torn last column). Sizing one
    /// cell larger biases ghostty's grid to ≥ the tmux pane size — the worst case
    /// is one blank trailing column/row, which the container clips, rather than a
    /// torn TUI.
    private func exactSurfaceSize(_ p: Pane, _ ppc: CGSize) -> CGSize {
        CGSize(width: CGFloat(p.width + 1) * ppc.width,
               height: CGFloat(p.height + 1) * ppc.height)
    }

    private func paneTitle(for paneVM: PaneViewModel) -> String {
        let p = paneVM.pane
        let cmd = p.currentCommand?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = p.title?.trimmingCharacters(in: .whitespaces) ?? ""
        if !title.isEmpty, title != cmd { return cmd.isEmpty ? title : "\(cmd) — \(title)" }
        return cmd.isEmpty ? "shell" : cmd
    }

    private func updateActiveBorders() {
        let active = viewModel.activePaneID
        for (id, cell) in cells {
            cell.container.isActivePane = (id == active)
            if id == active { window?.makeFirstResponder(cell.surface) }
        }
    }

    // MARK: - Pane geometry queries (used by the divider overlay)

    /// All current cell frames keyed by pane id.
    var cellFrames: [(id: TmuxPaneID, frame: NSRect)] {
        cells.compactMap { id, cell in
            cell.container.isHidden ? nil : (id, cell.container.frame)
        }
    }

    /// Resize the boundary owned by `paneID` along an axis by a signed cell delta.
    /// Vertical divider → grow/shrink to the Right/Left; horizontal → Down/Up.
    func resizeBoundary(paneID: TmuxPaneID, vertical: Bool, deltaCells: Int) {
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

    private var activePaneID: TmuxPaneID? { viewModel.activePaneID }

    /// Panes ordered top-to-bottom, left-to-right for stable navigation.
    private var orderedPaneIDs: [TmuxPaneID] {
        viewModel.paneViewModels
            .sorted { ($0.pane.y, $0.pane.x) < ($1.pane.y, $1.pane.x) }
            .map(\.paneID)
    }

    @objc public func splitPaneVertically(_ sender: Any?) {
        // iTerm2 "Split Vertically" = side-by-side panes (a vertical divider).
        viewModel.splitPane(horizontal: true)
    }

    @objc public func splitPaneHorizontally(_ sender: Any?) {
        // iTerm2 "Split Horizontally" = stacked panes (a horizontal divider).
        viewModel.splitPane(horizontal: false)
    }

    @objc public func closeCurrentPane(_ sender: Any?) {
        guard let active = activePaneID else { return }
        viewModel.closePane(active)
    }

    @objc public func toggleCurrentPaneZoom(_ sender: Any?) {
        guard let active = activePaneID else { return }
        viewModel.toggleZoom(active)
    }

    @objc public func selectNextPane(_ sender: Any?) {
        cyclePane(by: 1)
    }

    @objc public func selectPreviousPane(_ sender: Any?) {
        cyclePane(by: -1)
    }

    @objc public func newTerminalWindow(_ sender: Any?) {
        BentoTerminalWindow.newWindow()
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
    public static let splitVertically = #selector(GhosttyTiledPaneHost.splitPaneVertically(_:))
    public static let splitHorizontally = #selector(GhosttyTiledPaneHost.splitPaneHorizontally(_:))
    public static let closePane = #selector(GhosttyTiledPaneHost.closeCurrentPane(_:))
    public static let toggleZoom = #selector(GhosttyTiledPaneHost.toggleCurrentPaneZoom(_:))
    public static let nextPane = #selector(GhosttyTiledPaneHost.selectNextPane(_:))
    public static let previousPane = #selector(GhosttyTiledPaneHost.selectPreviousPane(_:))
    public static let newWindow = #selector(GhosttyTiledPaneHost.newTerminalWindow(_:))

    /// Dispatch an action through the responder chain (nil target → focused host).
    @MainActor public static func dispatch(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

// MARK: - Pane container (title bar + terminal surface)

@MainActor
final class PaneCellView: NSView {
    var onClick: (() -> Void)?
    var onZoom: (() -> Void)? {
        didSet { titleBar.onZoom = onZoom }
    }
    var onMenu: (() -> Void)? {
        didSet { titleBar.onMenu = onMenu }
    }
    private let titleBar = PaneTitleBar()
    private weak var surface: NSView?

    /// Exact terminal size (points) = tmux cols×rows × cell size. When set, the
    /// surface is sized to this (top-left under the title bar) so ghostty's grid
    /// matches tmux's pane grid; nil means fill the available area.
    var terminalCellSize: CGSize? {
        didSet { needsLayout = true }
    }

    /// The button the per-pane menu should anchor to.
    var menuButtonAnchor: NSView { titleBar.menuButton }

    var title: String = "" {
        didSet { titleBar.text = title }
    }

    var paneState: PaneState = .idle {
        didSet { titleBar.paneState = paneState }
    }

    var isActivePane: Bool = false {
        didSet {
            layer?.borderWidth = isActivePane ? 1.5 : 0.5
            layer?.borderColor = isActivePane
                ? GhosttyPaneColors.accent
                : NSColor(white: 1, alpha: 0.10).cgColor
            titleBar.isActive = isActivePane
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Clip the surface: it is sized one cell larger than the pane (see
        // exactSurfaceSize) so ghostty doesn't drop a column; the overflow is
        // a blank trailing column/row we hide here.
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        addSubview(titleBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func embed(_ view: NSView) {
        surface = view
        addSubview(view, positioned: .below, relativeTo: titleBar)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = GhosttyTiledPaneHost.titleBarHeight
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        // Use the exact tmux cell size when known (may slightly overflow the
        // container by design — see exactSurfaceSize; the overflow is clipped).
        // Fall back to filling the available area before the cell size is known.
        let w = terminalCellSize?.width ?? bounds.width
        let surfH = terminalCellSize?.height ?? max(bounds.height - h, 0)
        surface?.frame = NSRect(x: 0, y: h, width: w, height: surfH)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

/// The thin label strip atop each pane, with zoom + menu buttons on the right.
@MainActor
final class PaneTitleBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let stateDot = NSView()
    let zoomButton = NSButton()
    let menuButton = NSButton()
    var onZoom: (() -> Void)?
    var onMenu: (() -> Void)?

    var text: String = "" {
        didSet { label.stringValue = text }
    }

    /// Pane working/idle/awaiting — drives the status dot (amber = awaiting).
    var paneState: PaneState = .idle {
        didSet { stateDot.layer?.backgroundColor = paneState.nsColor.cgColor }
    }

    var isActive: Bool = false {
        didSet {
            layer?.backgroundColor = (isActive
                ? NSColor(srgbRed: 0.12, green: 0.26, blue: 0.20, alpha: 1.0)
                : NSColor(white: 0.12, alpha: 1.0)).cgColor
            label.textColor = isActive
                ? GhosttyPaneColors.accentNSColor
                : NSColor(white: 0.65, alpha: 1.0)
            let tint: NSColor = isActive ? GhosttyPaneColors.accentNSColor : NSColor(white: 0.65, alpha: 1.0)
            zoomButton.contentTintColor = tint
            menuButton.contentTintColor = tint
        }
    }

    /// Square hit target for each title-bar button.
    private static let buttonSize: CGFloat = 14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor

        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 3
        stateDot.layer?.backgroundColor = paneState.nsColor.cgColor
        addSubview(stateDot)

        configure(zoomButton, symbol: "arrow.up.left.and.arrow.down.right",
                  fallback: "⤢", action: #selector(zoomTapped))
        configure(menuButton, symbol: "ellipsis", fallback: "⋯", action: #selector(menuTapped))

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(white: 0.65, alpha: 1.0)
        label.lineBreakMode = .byTruncatingTail
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.cell?.usesSingleLineMode = true
        addSubview(label)
    }

    /// Manual layout (the bar's own frame is set by the parent), so the buttons
    /// sit at a fixed small size flush-right and never depend on intrinsic sizes.
    override func layout() {
        super.layout()
        let s = Self.buttonSize
        let y = ((bounds.height - s) / 2).rounded()
        let menuX = bounds.width - 6 - s
        let zoomX = menuX - 4 - s
        menuButton.frame = NSRect(x: menuX, y: y, width: s, height: s)
        zoomButton.frame = NSRect(x: zoomX, y: y, width: s, height: s)
        let dot: CGFloat = 6
        stateDot.frame = NSRect(x: 8, y: ((bounds.height - dot) / 2).rounded(), width: dot, height: dot)
        let labelX = stateDot.frame.maxX + 6
        let labelRight = zoomX - 6
        label.frame = NSRect(x: labelX, y: 0, width: max(labelRight - labelX, 0), height: bounds.height)
    }

    private func configure(_ button: NSButton, symbol: String, fallback: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.contentTintColor = NSColor(white: 0.65, alpha: 1.0)
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            button.image = img
        } else {
            button.imagePosition = .noImage
            button.title = fallback
            button.font = .systemFont(ofSize: 10)
        }
        addSubview(button)
    }

    @objc private func zoomTapped() { onZoom?() }
    @objc private func menuTapped() { onMenu?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // Let the buttons receive clicks, but everything else falls through to the
    // pane container (so clicking the title to focus the pane still works).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return (hit === zoomButton || hit === menuButton) ? hit : nil
    }
}

enum GhosttyPaneColors {
    static let accent = NSColor(srgbRed: 0.20, green: 0.80, blue: 0.55, alpha: 1.0).cgColor
    static let accentNSColor = NSColor(srgbRed: 0.30, green: 0.90, blue: 0.62, alpha: 1.0)
}

// MARK: - Divider overlay (drag to resize)

/// A transparent overlay covering the whole host. It is hit-test-transparent
/// except within a few points of a divider between two adjacent panes, where it
/// claims the mouse to drag-resize (and shows a resize cursor). Everywhere else
/// clicks fall through to the panes.
@MainActor
final class DividerOverlay: NSView {
    weak var host: GhosttyTiledPaneHost?

    /// A draggable boundary: the pane that owns it, orientation, and hot rect.
    private struct Divider {
        let paneID: TmuxPaneID
        let vertical: Bool   // true = vertical line, drags left/right
        let position: CGFloat // x (vertical) or y (horizontal), in points
        let hotRect: NSRect
    }

    private var dividers: [Divider] = []
    private static let hotThickness: CGFloat = 10

    // Active drag state.
    private var dragDivider: Divider?
    private var dragStart: NSPoint = .zero
    private var dragSentCells: Int = 0
    /// Live cursor coordinate (x for vertical, y for horizontal) during a drag.
    private var dragLivePos: CGFloat?

    override var isFlipped: Bool { true }

    /// Recompute divider hot zones from the host's current cell frames.
    func refresh() {
        dividers = computeDividers()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: - Drawing (visual feedback)

    override func draw(_ dirtyRect: NSRect) {
        for d in dividers {
            strokeLine(vertical: d.vertical, at: d.position, span: d.hotRect,
                       color: NSColor(white: 1, alpha: 0.18), width: 1)
        }
        // The line being dragged tracks the cursor live (tmux relayout lags
        // behind), drawn in the accent colour so the drag is clearly visible.
        if let d = dragDivider, let pos = dragLivePos {
            strokeLine(vertical: d.vertical, at: pos, span: d.hotRect,
                       color: GhosttyPaneColors.accentNSColor, width: 2)
        }
    }

    private func strokeLine(vertical: Bool, at pos: CGFloat, span: NSRect,
                            color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        if vertical {
            path.move(to: NSPoint(x: pos, y: span.minY))
            path.line(to: NSPoint(x: pos, y: span.maxY))
        } else {
            path.move(to: NSPoint(x: span.minX, y: pos))
            path.line(to: NSPoint(x: span.maxX, y: pos))
        }
        path.stroke()
    }

    private func computeDividers() -> [Divider] {
        guard let host else { return [] }
        let frames = host.cellFrames
        guard frames.count > 1 else { return [] }
        // Proportional tiling leaves a ~1-cell GAP between adjacent panes (the
        // tmux divider column), so neighbours don't share a coincident edge.
        // Match across that gap, and centre the hot zone within it.
        let cell = pointsPerCell() ?? CGPoint(x: 8, y: 8)
        let gapTolX = max(cell.x * 1.8, 6)
        let gapTolY = max(cell.y * 1.8, 6)
        let eps: CGFloat = 2
        var result: [Divider] = []

        for a in frames {
            // Vertical divider: a pane sits just to the right of a's right edge.
            let rightEdge = a.frame.maxX
            if rightEdge < bounds.width - eps {
                let neighbors = frames.filter {
                    $0.frame.minX > rightEdge - eps
                        && $0.frame.minX - rightEdge < gapTolX
                        && yOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minX).min() {
                    let pos = (rightEdge + nearest) / 2
                    let yTop = neighbors.map { max($0.frame.minY, a.frame.minY) }.min() ?? a.frame.minY
                    let yBot = neighbors.map { min($0.frame.maxY, a.frame.maxY) }.max() ?? a.frame.maxY
                    result.append(Divider(
                        paneID: a.id, vertical: true, position: pos,
                        hotRect: NSRect(x: pos - Self.hotThickness / 2, y: yTop,
                                        width: Self.hotThickness, height: yBot - yTop)
                    ))
                }
            }
            // Horizontal divider: a pane sits just below a's bottom edge.
            let bottomEdge = a.frame.maxY
            if bottomEdge < bounds.height - eps {
                let neighbors = frames.filter {
                    $0.frame.minY > bottomEdge - eps
                        && $0.frame.minY - bottomEdge < gapTolY
                        && xOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minY).min() {
                    let pos = (bottomEdge + nearest) / 2
                    let xL = neighbors.map { max($0.frame.minX, a.frame.minX) }.min() ?? a.frame.minX
                    let xR = neighbors.map { min($0.frame.maxX, a.frame.maxX) }.max() ?? a.frame.maxX
                    result.append(Divider(
                        paneID: a.id, vertical: false, position: pos,
                        hotRect: NSRect(x: xL, y: pos - Self.hotThickness / 2,
                                        width: xR - xL, height: Self.hotThickness)
                    ))
                }
            }
        }
        return result
    }

    private func yOverlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        min(a.maxY, b.maxY) - max(a.minY, b.minY)
    }
    private func xOverlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }

    private func divider(at point: NSPoint) -> Divider? {
        dividers.first { $0.hotRect.contains(point) }
    }

    // Transparent except over a divider hot zone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return divider(at: local) != nil ? self : nil
    }

    override func resetCursorRects() {
        for d in dividers {
            addCursorRect(d.hotRect, cursor: d.vertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragDivider = divider(at: p)
        dragStart = p
        dragSentCells = 0
        dragLivePos = dragDivider.map { $0.vertical ? p.x : p.y }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host, let d = dragDivider, let cellPts = pointsPerCell() else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragLivePos = d.vertical ? p.x : p.y
        needsDisplay = true
        let deltaPts = d.vertical ? (p.x - dragStart.x) : (p.y - dragStart.y)
        let perCell = d.vertical ? cellPts.x : cellPts.y
        guard perCell > 0 else { return }
        let totalCells = Int((deltaPts / perCell).rounded())
        let incremental = totalCells - dragSentCells
        guard incremental != 0 else { return }
        dragSentCells = totalCells
        host.resizeBoundary(paneID: d.paneID, vertical: d.vertical, deltaCells: incremental)
    }

    override func mouseUp(with event: NSEvent) {
        dragDivider = nil
        dragSentCells = 0
        dragLivePos = nil
        needsDisplay = true
    }

    /// Points per tmux cell along each axis (proportional tiling = bounds / grid).
    private func pointsPerCell() -> CGPoint? {
        guard let host, bounds.width > 0, bounds.height > 0 else { return nil }
        let grid = host.paneGridSize
        guard grid.cols > 0, grid.rows > 0 else { return nil }
        return CGPoint(x: bounds.width / grid.cols, y: bounds.height / grid.rows)
    }
}

private struct PaneCell {
    let container: PaneCellView
    let surface: GhosttyTerminalSurface
}
#endif
