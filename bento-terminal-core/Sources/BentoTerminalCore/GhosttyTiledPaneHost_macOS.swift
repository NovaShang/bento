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
    private let theme: TerminalTheme
    private var cells: [TmuxPaneID: PaneCell] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Cell size in pixels (constant for the font); learned from the first surface.
    private var cellPx: CGSize?
    private var resizeDebounce: DispatchWorkItem?
    private var lastClient: (cols: Int, rows: Int)?
    private let dividerOverlay = DividerOverlay()

    /// Height (points) of each pane's title strip. Reserved out of the terminal
    /// area so the tmux client size we report matches the visible grid.
    static let titleBarHeight: CGFloat = 18

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
        surface.onSplit = { [weak self] horizontal in
            self?.viewModel.selectPane(paneID)
            self?.viewModel.splitPane(horizontal: horizontal)
        }
        // A pane surface must NOT drive the tmux client size — tmux owns the
        // layout; the host computes the client size from the window. We only
        // use the surface's report to learn the font cell size (px).
        surface.onSizeChanged = { [weak self] size in
            guard let self, self.cellPx == nil,
                  size.cellWidthPx > 0, size.cellHeightPx > 0 else { return }
            self.cellPx = CGSize(width: size.cellWidthPx, height: size.cellHeightPx)
            self.recomputeClientSize()
            self.layoutCells()
        }

        let container = PaneCellView()
        container.onClick = { [weak self] in self?.viewModel.selectPane(paneID) }
        container.embed(surface)
        // Insert BELOW the divider overlay so dividers stay hit-testable on top.
        addSubview(container, positioned: .below, relativeTo: dividerOverlay)

        return PaneCell(container: container, surface: surface)
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

    /// Convert the window pixel size → tmux client cols×rows and push it (debounced).
    /// Title-bar space is subtracted so the reported grid matches what's visible.
    private func recomputeClientSize() {
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

    /// Tile panes proportionally to fill the host, using the bounding box of all
    /// panes as the cell grid. When a pane is zoomed, it alone fills the host and
    /// the rest are hidden (iTerm2 zoom).
    private func layoutCells() {
        let panes = viewModel.paneViewModels
        guard !panes.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        if let zoomed = viewModel.zoomedPaneID, cells[zoomed] != nil {
            for (id, cell) in cells {
                let isZoom = (id == zoomed)
                cell.container.isHidden = !isZoom
                if isZoom { cell.container.frame = bounds }
            }
            dividerOverlay.refresh()
            return
        }

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
            cell.container.title = paneTitle(for: paneVM)
        }
        dividerOverlay.refresh()
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
    private let titleBar = PaneTitleBar()
    private weak var surface: NSView?

    var title: String = "" {
        didSet { titleBar.text = title }
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
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        addSubview(titleBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func embed(_ view: NSView) {
        surface = view
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = GhosttyTiledPaneHost.titleBarHeight
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        surface?.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(bounds.height - h, 0))
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

/// The thin label strip atop each pane.
@MainActor
final class PaneTitleBar: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String = "" {
        didSet { label.stringValue = text }
    }

    var isActive: Bool = false {
        didSet {
            layer?.backgroundColor = (isActive
                ? NSColor(srgbRed: 0.12, green: 0.26, blue: 0.20, alpha: 1.0)
                : NSColor(white: 0.12, alpha: 1.0)).cgColor
            label.textColor = isActive
                ? GhosttyPaneColors.accentNSColor
                : NSColor(white: 0.65, alpha: 1.0)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(white: 0.65, alpha: 1.0)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    // Don't intercept clicks — let them fall through to the pane container.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

    override var isFlipped: Bool { true }

    /// Recompute divider hot zones from the host's current cell frames.
    func refresh() {
        dividers = computeDividers()
        window?.invalidateCursorRects(for: self)
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
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host, let d = dragDivider, let cellPts = pointsPerCell() else { return }
        let p = convert(event.locationInWindow, from: nil)
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
