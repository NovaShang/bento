#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftTmux

/// iTerm2-style TILED multi-pane host for macOS. Every tmux pane is shown at
/// once, laid out by its tmux cell geometry (x/y/width/height), each in its own
/// GhosttyTerminalSurface fed by its PaneViewModel. The window's pixel size is
/// converted (via the font cell size) to a tmux client cols×rows; tmux owns the
/// split layout and we mirror it. Click a pane to focus it; the active pane gets
/// an accent border.
@MainActor
public final class GhosttyTiledPaneHost: NSView {
    private let viewModel: TerminalViewModel
    private let theme: TerminalTheme
    private var cells: [TmuxPaneID: PaneCell] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Cell size in pixels (constant for the font); learned from the first surface.
    private var cellPx: CGSize?
    private var resizeDebounce: DispatchWorkItem?
    private var lastClient: (cols: Int, rows: Int)?

    public init(viewModel: TerminalViewModel, theme: TerminalTheme) {
        self.viewModel = viewModel
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).cgColor

        viewModel.$paneViewModels
            .receive(on: RunLoop.main)
            .sink { [weak self] panes in self?.syncPanes(panes) }
            .store(in: &cancellables)
        viewModel.$activePaneID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateActiveBorders() }
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
        surface.frame = container.bounds
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
        addSubview(container)

        return PaneCell(container: container, surface: surface)
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        recomputeClientSize()
        layoutCells()
    }

    private var currentScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    /// Convert the window pixel size → tmux client cols×rows and push it (debounced).
    private func recomputeClientSize() {
        guard let cellPx, bounds.width > 0, bounds.height > 0 else { return }
        let scale = currentScale
        let cols = max(Int((bounds.width * scale) / cellPx.width), 2)
        let rows = max(Int((bounds.height * scale) / cellPx.height), 1)
        guard lastClient?.cols != cols || lastClient?.rows != rows else { return }
        lastClient = (cols, rows)
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.viewModel.resizeTmuxClient(cols: cols, rows: rows)
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Tile panes proportionally to fill the host, using the bounding box of all
    /// panes as the cell grid. This always fills the window regardless of cell
    /// size; recomputeClientSize then matches the tmux grid to the window's cell
    /// capacity so text is crisp (not stretched).
    private func layoutCells() {
        let panes = viewModel.paneViewModels
        guard !panes.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let totalCols = CGFloat(max(panes.map { $0.pane.x + $0.pane.width }.max() ?? 1, 1))
        let totalRows = CGFloat(max(panes.map { $0.pane.y + $0.pane.height }.max() ?? 1, 1))
        let W = bounds.width, H = bounds.height
        for (id, cell) in cells {
            guard let paneVM = panes.first(where: { $0.paneID == id }) else { continue }
            let p = paneVM.pane
            cell.container.frame = NSRect(
                x: (CGFloat(p.x) / totalCols) * W,
                y: (CGFloat(p.y) / totalRows) * H,
                width: (CGFloat(p.width) / totalCols) * W,
                height: (CGFloat(p.height) / totalRows) * H
            )
        }
    }

    private func updateActiveBorders() {
        let active = viewModel.activePaneID
        for (id, cell) in cells {
            cell.container.isActivePane = (id == active)
            if id == active { window?.makeFirstResponder(cell.surface) }
        }
    }
}

/// A pane container that draws an accent border when active and forwards clicks.
@MainActor
final class PaneCellView: NSView {
    var onClick: (() -> Void)?
    var isActivePane: Bool = false {
        didSet {
            layer?.borderWidth = isActivePane ? 1.5 : 0.5
            layer?.borderColor = (isActivePane
                ? NSColor(srgbRed: 0.20, green: 0.80, blue: 0.55, alpha: 1.0)
                : NSColor(white: 1, alpha: 0.10)).cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

private struct PaneCell {
    let container: PaneCellView
    let surface: GhosttyTerminalSurface
}
#endif
