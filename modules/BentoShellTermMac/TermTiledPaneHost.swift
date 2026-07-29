#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoTerminalPane
import BentoUI
import BentoWorkbench
import Combine

/// Product B's Parallel-view tiled pane host: a tmux window's panes shown at
/// once, each an engine terminal surface built through the `PaneModuleRegistry`
/// (→ `TmuxPaneModule`), not a hardcoded class — the seam-one payoff. It is the
/// term twin of BentoShellMac's `TiledPaneHost`, but drives directly off
/// `TermWorkspaceModel` + the store, with no ACP `WorkspaceViewModel`.
///
/// Fidelity note (flagged): layout is FRACTIONAL from the mirror's LayoutTree
/// projection, NOT the frozen product's cell-exact (+1-cell) tmux geometry.
/// Sizing is the daemon's now (setSizePolicy/viewport, docs/tmux-host-design
/// §5.5) — the client renders the projection and does not push a client size.
@MainActor
public final class TermTiledPaneHost: NSView, NSMenuDelegate {
    private let model: TermWorkspaceModel
    private var theme: CanvasTheme
    private var cells: [PaneID: Cell] = [:]
    private var bag = Set<AnyCancellable>()

    private struct Cell {
        let container: TermPaneCellView
        let surface: NSView
        var terminal: GhosttyTerminalSurface? { surface as? GhosttyTerminalSurface }
    }

    public init(model: TermWorkspaceModel, theme: CanvasTheme) {
        self.model = model
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TermColors.rgb(theme.background).cgColor

        model.$panes
            .receive(on: RunLoop.main)
            .sink { [weak self] panes in self?.syncPanes(panes) }
            .store(in: &bag)
        model.$activePaneID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutCells(); self?.updateBorders() }
            .store(in: &bag)
        model.$zoomedPaneID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutCells() }
            .store(in: &bag)
        model.$mode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutCells(); self?.updateBorders() }
            .store(in: &bag)
        model.$stateVersion
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &bag)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public func teardown() {
        bag.removeAll()
        for (_, cell) in cells { cell.terminal?.teardown() }
        cells.removeAll()
    }

    // MARK: - Pane lifecycle

    private func syncPanes(_ panes: [Pane]) {
        let ids = Set(panes.map(\.id))
        for (id, cell) in cells where !ids.contains(id) {
            cell.terminal?.teardown()
            cell.container.removeFromSuperview()
            cells[id] = nil
        }
        for pane in panes where cells[pane.id] == nil {
            cells[pane.id] = makeCell(for: pane)
        }
        layoutCells()
        updateBorders()
        refreshStatus()
    }

    private func makeCell(for pane: Pane) -> Cell {
        let surface = PaneModuleRegistry.shared.makeSurface(
            for: pane.id, in: TermShell.store, theme: theme) ?? NSView()
        if let term = surface as? GhosttyTerminalSurface {
            term.onSelect = { [weak self] in self?.model.selectPane(pane.id) }
        }
        let container = TermPaneCellView()
        container.title = pane.chromeTitle
        container.onClick = { [weak self] in self?.model.selectPane(pane.id) }
        container.onFocus = { [weak self] in
            self?.model.selectPane(pane.id)
            self?.model.setMode(.list)
        }
        container.onClose = { [weak self] in self?.model.closePane(pane.id) }
        container.onPaneDrag = { [weak self] phase in self?.handleDrag(source: pane.id, phase: phase) }
        container.embed(surface)
        addSubview(container)
        return Cell(container: container, surface: surface)
    }

    // MARK: - Layout (fractional projection)

    /// The one pane that fills the host alone: an explicit zoom, or Focus mode.
    private var soloPaneID: PaneID? {
        if let z = model.zoomedPaneID { return z }
        if model.mode == .list { return model.activePaneID ?? model.panes.first?.id }
        return nil
    }

    private var isSingleOrZoom: Bool { soloPaneID != nil || model.panes.count <= 1 }

    public override func layout() {
        super.layout()
        layoutCells()
    }

    private func layoutCells() {
        let panes = model.panes
        guard !panes.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let byID = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let focusMode = model.mode == .list
        let titleBar: CGFloat = focusMode ? 0 : 22

        for (_, cell) in cells { cell.container.titleBarHeight = titleBar }

        if let solo = soloPaneID, cells[solo] != nil {
            for (id, cell) in cells {
                let show = id == solo
                cell.container.isHidden = !show
                if show {
                    cell.container.surfaceInsetX = 0
                    cell.container.frame = bounds
                }
            }
            return
        }

        let cols = CGFloat(max(panes.map { $0.x + $0.width }.max() ?? 1, 1))
        let rows = CGFloat(max(panes.map { $0.y + $0.height }.max() ?? 1, 1))
        let fx = bounds.width / cols
        let fy = bounds.height / rows
        for (id, cell) in cells {
            guard let p = byID[id] else { continue }
            cell.container.isHidden = false
            cell.container.title = p.chromeTitle
            if panes.count == 1 {
                cell.container.surfaceInsetX = 0
                cell.container.frame = bounds
            } else {
                cell.container.surfaceInsetX = 3
                cell.container.frame = backingAlignedRect(
                    NSRect(x: CGFloat(p.x) * fx, y: CGFloat(p.y) * fy,
                           width: CGFloat(p.width) * fx, height: CGFloat(p.height) * fy),
                    options: .alignAllEdgesNearest)
            }
        }
    }

    private func updateBorders() {
        let active = model.activePaneID
        let suppress = isSingleOrZoom
        for (id, cell) in cells {
            cell.container.focusSuppressed = suppress
            cell.container.isActivePane = (id == active)
            if id == active, window?.firstResponder !== cell.surface,
               !(cell.terminal?.searchFieldHasFocus ?? false),
               !((window?.firstResponder as? NSView)?.isDescendant(of: cell.surface) ?? false) {
                window?.makeFirstResponder(cell.surface)
            }
            // Follow-focus find: close a stale find bar on a now-inactive pane.
            if id != active, cell.terminal?.isSearchOpen == true {
                cell.terminal?.endSearchUI()
            }
        }
    }

    private func refreshStatus() {
        for (id, cell) in cells {
            cell.container.status = model.paneStatus(id.raw)
        }
    }

    // MARK: - Drag-to-dock (swap / dock beside)

    private var dragSource: PaneID?

    private func handleDrag(source: PaneID, phase: PaneDragPhase) {
        switch phase {
        case .moved(let pt):
            if dragSource == nil { dragSource = source; cells[source]?.container.alphaValue = 0.6 }
            _ = pt
        case .ended(let pt):
            cells[source]?.container.alphaValue = 1
            dragSource = nil
            guard let (target, zone) = dropTarget(at: pt, excluding: source) else { return }
            switch zone {
            case .swap:
                model.swapPanes(source, target)
            case .dock(let horizontal, let before):
                model.dockPane(source, splitting: target, horizontal: horizontal, before: before)
            }
        }
    }

    private enum DropZone { case swap; case dock(horizontal: Bool, before: Bool) }

    private func dropTarget(at windowPoint: NSPoint, excluding source: PaneID)
        -> (PaneID, DropZone)? {
        let local = convert(windowPoint, from: nil)
        guard let (id, cell) = cells.first(where: { id, cell in
            id != source && !cell.container.isHidden && cell.container.frame.contains(local)
        }) else { return nil }
        let f = cell.container.frame
        let rx = (local.x - f.minX) / f.width
        let ry = (local.y - f.minY) / f.height
        // Center 50% → swap; else dock on the nearest edge.
        if rx > 0.25, rx < 0.75, ry > 0.25, ry < 0.75 { return (id, .swap) }
        let leftD = rx, rightD = 1 - rx, topD = ry, bottomD = 1 - ry
        let minD = min(leftD, rightD, topD, bottomD)
        if minD == leftD { return (id, .dock(horizontal: true, before: true)) }
        if minD == rightD { return (id, .dock(horizontal: true, before: false)) }
        if minD == topD { return (id, .dock(horizontal: false, before: true)) }
        return (id, .dock(horizontal: false, before: false))
    }

    // MARK: - Responder-chain actions (the Shell menu dispatches here)

    private var activeTerminal: GhosttyTerminalSurface? {
        if let id = model.activePaneID, let t = cells[id]?.terminal { return t }
        return cells.values.first?.terminal
    }

    private var orderedPaneIDs: [PaneID] {
        model.panes.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.id)
    }

    @objc public func splitPaneVertically(_ sender: Any?) { model.splitActivePane(horizontal: true) }
    @objc public func splitPaneHorizontally(_ sender: Any?) { model.splitActivePane(horizontal: false) }
    @objc public func closeCurrentPane(_ sender: Any?) { model.closeActivePane() }
    @objc public func toggleCurrentPaneZoom(_ sender: Any?) { model.toggleZoomActive() }
    @objc public func swapActivePaneUp(_ sender: Any?) { model.swapActivePane(up: true) }
    @objc public func swapActivePaneDown(_ sender: Any?) { model.swapActivePane(up: false) }
    @objc public func selectNextPane(_ sender: Any?) { cyclePane(by: 1) }
    @objc public func selectPreviousPane(_ sender: Any?) { cyclePane(by: -1) }

    @objc public func findInPane(_ sender: Any?) { activeTerminal?.beginSearch() }
    @objc public func findNextMatch(_ sender: Any?) { activeTerminal?.findNext() }
    @objc public func findPreviousMatch(_ sender: Any?) { activeTerminal?.findPrevious() }
    @objc public func useSelectionForFind(_ sender: Any?) { activeTerminal?.useSelectionForFind() }

    @objc public func selectWindow0(_ s: Any?) { model.selectWindowIndex(0) }
    @objc public func selectWindow1(_ s: Any?) { model.selectWindowIndex(1) }
    @objc public func selectWindow2(_ s: Any?) { model.selectWindowIndex(2) }
    @objc public func selectWindow3(_ s: Any?) { model.selectWindowIndex(3) }
    @objc public func selectWindow4(_ s: Any?) { model.selectWindowIndex(4) }
    @objc public func selectWindow5(_ s: Any?) { model.selectWindowIndex(5) }
    @objc public func selectWindow6(_ s: Any?) { model.selectWindowIndex(6) }
    @objc public func selectWindow7(_ s: Any?) { model.selectWindowIndex(7) }
    @objc public func selectWindow8(_ s: Any?) { model.selectWindowIndex(8) }
    @objc public func selectWindow9(_ s: Any?) { model.selectWindowIndex(9) }

    @objc public func newTmuxWindow(_ sender: Any?) { model.newWindow() }

    private func cyclePane(by step: Int) {
        let ids = orderedPaneIDs
        guard !ids.isEmpty else { return }
        let cur = model.activePaneID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = ((cur + step) % ids.count + ids.count) % ids.count
        model.selectPane(ids[next])
    }
}

/// Selectors the Shell menu (SwiftUI `.commands`) dispatches through the
/// responder chain to the focused host — B keeps tmux semantics: ⌘0-9 =
/// select tmux WINDOW by index, ⇧⌘↩ = zoom, ⌘E = use selection for find.
public enum BentoTermPaneAction {
    public static let splitVertically = #selector(TermTiledPaneHost.splitPaneVertically(_:))
    public static let splitHorizontally = #selector(TermTiledPaneHost.splitPaneHorizontally(_:))
    public static let closePane = #selector(TermTiledPaneHost.closeCurrentPane(_:))
    public static let toggleZoom = #selector(TermTiledPaneHost.toggleCurrentPaneZoom(_:))
    public static let swapPaneUp = #selector(TermTiledPaneHost.swapActivePaneUp(_:))
    public static let swapPaneDown = #selector(TermTiledPaneHost.swapActivePaneDown(_:))
    public static let nextPane = #selector(TermTiledPaneHost.selectNextPane(_:))
    public static let previousPane = #selector(TermTiledPaneHost.selectPreviousPane(_:))
    public static let newTmuxWindow = #selector(TermTiledPaneHost.newTmuxWindow(_:))

    public static let findInPane = #selector(TermTiledPaneHost.findInPane(_:))
    public static let findNext = #selector(TermTiledPaneHost.findNextMatch(_:))
    public static let findPrevious = #selector(TermTiledPaneHost.findPreviousMatch(_:))
    public static let useSelectionForFind = #selector(TermTiledPaneHost.useSelectionForFind(_:))

    /// ⌘0-9 → the window whose tmux index is that digit (slot N = ⌘N).
    public static let selectWindow: [Selector] = [
        #selector(TermTiledPaneHost.selectWindow0(_:)),
        #selector(TermTiledPaneHost.selectWindow1(_:)),
        #selector(TermTiledPaneHost.selectWindow2(_:)),
        #selector(TermTiledPaneHost.selectWindow3(_:)),
        #selector(TermTiledPaneHost.selectWindow4(_:)),
        #selector(TermTiledPaneHost.selectWindow5(_:)),
        #selector(TermTiledPaneHost.selectWindow6(_:)),
        #selector(TermTiledPaneHost.selectWindow7(_:)),
        #selector(TermTiledPaneHost.selectWindow8(_:)),
        #selector(TermTiledPaneHost.selectWindow9(_:)),
    ]

    @MainActor public static func dispatch(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
#endif
