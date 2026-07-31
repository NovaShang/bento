#if canImport(UIKit)
import UIKit
import SwiftUI
import BentoFoundation
import BentoUI
import BentoWorkbench
import BentoVoiceKit
import BentoFilePreviewKit
import BentoLink

// MARK: - Pane container

/// Hosts the live panes. Two layouts:
///   - **Tiles**: every workspace pane shown at once, positioned
///     proportionally by its layout-tree cell geometry. Tap = select-pane.
///   - **Focus**: a single pane (active or zoomed) fills the viewport.
final class PaneContainerVC: UIViewController {
    var viewModel: WorkspaceViewModel? {
        didSet { wireGeometryHook() }
    }
    var voiceController: VoiceInputController?
    /// Workspace preview driver, threaded down to each pane's chat VC so a
    /// tapped file path opens in the shared panel.
    weak var previewPresenter: FilePreviewPresenter?

    /// Re-tile SYNCHRONOUSLY when new pane geometry is applied, so pane
    /// views resize in the same main-actor turn as the store mutation.
    private func wireGeometryHook() {
        viewModel?.onGeometryApplied = { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    /// Pane content controllers, one per pane. Built through the
    /// `ShellPaneRegistry` factory the app installs — the container never names
    /// the concrete pane type (ACP chat vs terminal vs file vs browser).
    private(set) var paneControllers: [PaneID: PaneSurfaceController] = [:]

    /// Holds the pane VCs; always exactly the viewport.
    private let contentView = UIView()

    /// The translucent landing preview shown while a title-bar drag hovers a
    /// target pane; created on the first hover of a drag, torn down when the
    /// drag ends. Mirrors the macOS host's PaneDropZoneOverlay.
    private var dropOverlay: PaneDropZoneOverlayView?

    /// Transparent overlay over the panes that claims touches only on a
    /// divider between adjacent panes, to drag-resize them. Mirrors the
    /// macOS `DividerOverlay`.
    private let dividerOverlay = TileDividerOverlay()

    // MARK: - Lifecycle

    /// The panes run to the bottom edge, so let the home indicator auto-dim.
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term.bg
        contentView.clipsToBounds = false
        view.addSubview(contentView)
        contentView.addSubview(dividerOverlay)
        dividerOverlay.onResize = { [weak self] paneID, vertical, deltaCells in
            self?.resizeBoundary(paneID: paneID, vertical: vertical, deltaCells: deltaCells)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activePaneAppearanceChanged),
            name: .terminalThemeChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Tear down every pane before this container is released.
    func teardownAll() {
        for vc in paneControllers.values { vc.teardown() }
    }

    @objc private func activePaneAppearanceChanged() {
        DispatchQueue.main.async { [weak self] in self?.syncBackgroundToActivePane() }
    }

    private func syncBackgroundToActivePane() {
        let bg = focusedOrActiveVC?.view.backgroundColor ?? STTheme.term.bg
        guard view.backgroundColor != bg else { return }
        UIView.animate(withDuration: 0.26) { self.view.backgroundColor = bg }
    }

    // MARK: - Focus / active resolution

    /// The keyboard / voice target VC: zoomed pane, else active.
    private var focusedOrActiveVC: PaneSurfaceController? {
        if let id = viewModel?.zoomedPaneID, let vc = paneControllers[id] { return vc }
        if let id = viewModel?.activePaneID, let vc = paneControllers[id] { return vc }
        return paneControllers.values.first
    }

    // MARK: - Pane reconciliation

    func refreshPanes() {
        guard let viewModel else { return }
        let currentIDs = Set(paneControllers.keys)
        let newIDs = Set(viewModel.paneViewModels.map(\.paneID))
        for id in currentIDs.subtracting(newIDs) {
            if let vc = paneControllers.removeValue(forKey: id) {
                vc.teardown()
                vc.willMove(toParent: nil)
                vc.view.removeFromSuperview()
                vc.removeFromParent()
            }
        }
        for paneVM in viewModel.paneViewModels where !currentIDs.contains(paneVM.paneID) {
            addPaneController(for: paneVM)
        }
        view.setNeedsLayout()
    }

    private func addPaneController(for paneVM: PaneViewModel) {
        guard let viewModel,
              let vc = ShellPaneRegistry.paneControllerFactory?(viewModel.workspace)
        else { return }
        let paneID = paneVM.paneID
        vc.voiceController = voiceController
        vc.previewPresenter = previewPresenter
        vc.bindToPaneVM(paneVM)
        vc.onSelectPaneTapped = { [weak self] in
            self?.viewModel?.selectPane(paneID)
            self?.view.setNeedsLayout()
        }
        vc.onTitleDrag = { [weak self] phase in
            self?.handleTitleSwap(source: paneID, phase: phase)
        }
        vc.onNewChat = { [weak self] in
            _ = self?.viewModel?.workspace.resetPane(paneID.raw)
        }
        vc.onFocusPane = { [weak self] in
            guard let vm = self?.viewModel else { return }
            if let zoomed = vm.zoomedPaneID { vm.toggleZoom(zoomed) }
            vm.setMode(.list)
        }
        vc.paneMenuProvider = { [weak self] in
            self?.paneMenuElements(for: paneID) ?? []
        }
        addChild(vc)
        contentView.addSubview(vc.view)
        vc.didMove(toParent: self)
        paneControllers[paneID] = vc
    }

    // MARK: - Pane menu (title-bar ⋯)

    /// The per-pane ⋯ menu, mirroring the macOS pane menu: split (Parallel
    /// only, where a split has somewhere to land), resume a past conversation,
    /// move the pane to another workspace, close it. Rebuilt on every open, so
    /// the mode-dependent entries and the workspace/history lists are current.
    private func paneMenuElements(for paneID: PaneID) -> [UIMenuElement] {
        guard let viewModel else { return [] }
        var elements: [UIMenuElement] = []

        if viewModel.workspaceMode != .list {
            // Icons mirror the resulting layout — two columns vs two rows —
            // and the titles name where the new pane lands, which the
            // ambiguous "vertical/horizontal" never did.
            elements.append(UIMenu(title: "", options: .displayInline, children: [
                UIAction(title: "Split Right",
                         image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                    self?.viewModel?.splitPane(horizontal: true)
                },
                UIAction(title: "Split Down",
                         image: UIImage(systemName: "rectangle.split.1x2")) { [weak self] _ in
                    self?.viewModel?.splitPane(horizontal: false)
                },
                UIAction(title: "Split — Duplicate This Pane",
                         image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    guard let vm = self?.viewModel else { return }
                    Task { await vm.splitPane(horizontal: true, seed: .duplicateCurrent) }
                },
            ]))
        }

        elements.append(resumeMenu())
        elements.append(moveToWorkspaceMenu(for: paneID))
        elements.append(UIMenu(title: "", options: .displayInline, children: [
            UIAction(title: "Close Pane", image: UIImage(systemName: "xmark"),
                     attributes: .destructive) { [weak self] _ in
                self?.confirmClose(paneID)
            },
        ]))
        return elements
    }

    /// Past conversations, reopenable in place — the same catalog the sidebar's
    /// History row lists. Empty catalog still shows (disabled) so the entry
    /// doesn't appear and disappear.
    private func resumeMenu() -> UIMenu {
        let entries = viewModel?.recentHistory() ?? []
        let liveIDs = viewModel?.liveHistoryIDs ?? []
        let children: [UIMenuElement] = entries.isEmpty
            ? [UIAction(title: "No Conversations", attributes: .disabled) { _ in }]
            : entries.map { entry in
                UIAction(title: entry.title.isEmpty ? "Untitled" : entry.title,
                         image: UIImage(systemName: liveIDs.contains(entry.acpSessionID)
                                        ? "dot.radiowaves.left.and.right"
                                        : "clock.arrow.circlepath")) { [weak self] _ in
                    guard let vm = self?.viewModel else { return }
                    Task { await vm.openHistory(entry) }
                }
            }
        return UIMenu(title: "Resume Conversation",
                      image: UIImage(systemName: "clock.arrow.circlepath"),
                      children: children)
    }

    /// Move this pane (still running) to another workspace, or to a new one.
    private func moveToWorkspaceMenu(for paneID: PaneID) -> UIMenu {
        let others = (viewModel?.availableSessions ?? [])
            .filter { $0 != viewModel?.activeWorkspaceName }
        var children: [UIMenuElement] = others.map { name in
            UIAction(title: name) { [weak self] _ in
                guard let vm = self?.viewModel else { return }
                Task { _ = await vm.movePane(paneID, toSession: name) }
            }
        }
        children.append(UIMenu(title: "", options: .displayInline, children: [
            UIAction(title: "New Workspace…", image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.promptMove(paneID)
            },
        ]))
        // Menus don't update while displayed, so warm the cache for the next open.
        if let vm = viewModel { Task { await vm.refreshSessions() } }
        return UIMenu(title: "Move to Workspace",
                      image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                      children: children)
    }

    /// Closing kills the agent running in the pane, so it confirms first.
    private func confirmClose(_ paneID: PaneID) {
        let name = viewModel?.paneDisplayName(paneID) ?? ""
        let alert = UIAlertController(
            title: "Close “\(name)”?",
            message: "The agent running in it will be terminated.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Close Pane", style: .destructive) { [weak self] _ in
            self?.viewModel?.closePane(paneID)
        })
        present(alert, animated: true)
    }

    /// "Move to Workspace → New Workspace…": name it, then move. The pane keeps
    /// running — it lands as a pane of the new workspace.
    private func promptMove(_ paneID: PaneID) {
        let alert = UIAlertController(
            title: "Move to New Workspace",
            message: "The pane keeps running — it moves to the new workspace.",
            preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Workspace name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Move", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text, !name.isEmpty,
                  let vm = self?.viewModel else { return }
            Task { _ = await vm.movePane(paneID, toSession: name) }
        })
        present(alert, animated: true)
    }

    // MARK: - Layout

    /// Whether we're showing a single full pane (Focus mode, zoomed, or a
    /// lone pane).
    private var isFocusLayout: Bool {
        viewModel?.zoomedPaneID != nil
            || (viewModel?.paneViewModels.count ?? 0) <= 1
            || viewModel?.workspaceMode == .list
    }

    private var effectiveFocusID: PaneID? {
        if let z = viewModel?.zoomedPaneID { return z }
        if (viewModel?.paneViewModels.count ?? 0) == 1 { return viewModel?.paneViewModels.first?.paneID }
        return viewModel?.activePaneID
    }

    /// The area the panes map to. Respects the TOP inset (the split view hosts
    /// us edge to edge, so without it the first row of pane title bars sits
    /// under the navigation bar's glass) and the LEFT/RIGHT ones (landscape
    /// notch). The BOTTOM is deliberately ignored — the panes run to the edge
    /// and the home indicator auto-dims over them.
    private var pageRect: CGRect {
        let insets = view.safeAreaInsets
        return CGRect(x: insets.left, y: insets.top,
                      width: max(0, view.bounds.width - insets.left - insets.right),
                      height: max(0, view.bounds.height - insets.top))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout() })
    }

    private func layoutPanes() {
        dividerOverlay.dividers = []
        guard let viewModel, !paneControllers.isEmpty else { return }
        let rect = pageRect
        contentView.frame = rect

        if isFocusLayout, let focusID = effectiveFocusID {
            layoutFocus(focusID, page: rect.size)
        } else {
            layoutTiles(viewModel.paneViewModels, page: rect.size)
        }
        syncBackgroundToActivePane()
    }

    /// Single pane fills the page; the rest are hidden.
    private func layoutFocus(_ focusID: PaneID, page: CGSize) {
        for (id, vc) in paneControllers {
            let isFocus = (id == focusID)
            vc.view.isHidden = !isFocus
            if isFocus {
                vc.tiled = false
                vc.titleBarHeight = type(of: vc).defaultTitleBarHeight
                vc.surfaceInsetX = 0
                vc.view.frame = CGRect(origin: .zero, size: page)
                vc.setActivePaneChrome(true)
                if let pvm = viewModel?.paneViewModels.first(where: { $0.paneID == focusID }) {
                    vc.updatePaneState(pvm.paneState, doneUnseen: pvm.agentFinishedUnseen,
                                       active: true)
                }
            }
        }
    }

    /// Horizontal inset between a pane's content and its container edge, so
    /// abutting tiles read as separate panes (matches the macOS host).
    private static let paneGutter: CGFloat = 3

    /// Tile all panes proportionally: each pane's frame is its layout-tree
    /// fraction (recovered from the legacy 160×48 projection) × the page.
    private func layoutTiles(_ panes: [PaneViewModel], page: CGSize) {
        let totalCols = CGFloat(max(panes.map { $0.pane.x + $0.pane.width }.max() ?? 1, 1))
        let totalRows = CGFloat(max(panes.map { $0.pane.y + $0.pane.height }.max() ?? 1, 1))
        let activeID = viewModel?.activePaneID
        for (id, vc) in paneControllers {
            guard let pvm = panes.first(where: { $0.paneID == id }) else { continue }
            let p = pvm.pane
            vc.view.isHidden = false
            vc.tiled = true
            vc.titleBarHeight = type(of: vc).defaultTitleBarHeight
            vc.surfaceInsetX = Self.paneGutter
            vc.view.frame = CGRect(
                x: (CGFloat(p.x) / totalCols) * page.width,
                y: (CGFloat(p.y) / totalRows) * page.height,
                width: (CGFloat(p.width) / totalCols) * page.width,
                height: (CGFloat(p.height) / totalRows) * page.height)
            vc.updatePaneState(pvm.paneState, doneUnseen: pvm.agentFinishedUnseen,
                               active: pvm.paneID == activeID)
        }
        // Refresh the drag-to-resize divider hot zones for the new geometry.
        // The synthetic per-cell size maps drag points back onto the legacy
        // 160×48 resize unit (one "cell" = 1/160 or 1/48 of the canvas), so
        // the divider tracks the finger 1:1.
        let synthPpc = CGSize(width: page.width / totalCols, height: page.height / totalRows)
        dividerOverlay.frame = CGRect(origin: .zero, size: page)
        dividerOverlay.pointsPerCell = CGPoint(x: synthPpc.width, y: synthPpc.height)
        dividerOverlay.dividers = computeTileDividers(page: page, ppc: synthPpc)
        contentView.bringSubviewToFront(dividerOverlay)
    }

    // MARK: - Divider resize

    /// Resize the boundary owned by `paneID` by a signed cell delta.
    /// Vertical divider → grow Right/shrink Left; horizontal → Down/Up.
    /// Identical mapping to the macOS host's `resizeBoundary`.
    private func resizeBoundary(paneID: PaneID, vertical: Bool, deltaCells: Int) {
        guard deltaCells != 0 else { return }
        let dir = vertical ? (deltaCells > 0 ? "R" : "L")
                           : (deltaCells > 0 ? "D" : "U")
        viewModel?.resizePaneBy(paneID, direction: dir, amount: abs(deltaCells))
    }

    /// Compute divider hot zones from the current pane frames, matching the
    /// macOS `computeDividers`. The vertical hot zone is centred on the
    /// line; the horizontal one sits just ABOVE it so it never covers the
    /// lower pane's title bar (the drag-to-swap handle).
    private func computeTileDividers(page: CGSize, ppc: CGSize) -> [TileDividerOverlay.Divider] {
        let frames: [(id: PaneID, frame: CGRect)] = paneControllers.compactMap { id, vc in
            vc.view.isHidden ? nil : (id, vc.view.frame)
        }
        guard frames.count > 1 else { return [] }
        let gapTolX = max(ppc.width * 1.8, 6)
        let gapTolY = max(ppc.height * 1.8, 6)
        let eps: CGFloat = 2
        let hotV = TileDividerOverlay.hotThicknessV
        let above = TileDividerOverlay.hotAboveLine
        let below = TileDividerOverlay.hotBelowLine
        var result: [TileDividerOverlay.Divider] = []

        for a in frames {
            // Vertical divider: a pane sits just to the right of a's right edge.
            let rightEdge = a.frame.maxX
            if rightEdge < page.width - eps {
                let neighbors = frames.filter {
                    $0.frame.minX > rightEdge - eps
                        && $0.frame.minX - rightEdge < gapTolX
                        && yOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minX).min() {
                    let pos = (rightEdge + nearest) / 2
                    let yTop = neighbors.map { max($0.frame.minY, a.frame.minY) }.min() ?? a.frame.minY
                    let yBot = neighbors.map { min($0.frame.maxY, a.frame.maxY) }.max() ?? a.frame.maxY
                    result.append(.init(paneID: a.id, vertical: true, position: pos,
                                        hotRect: CGRect(x: pos - hotV / 2, y: yTop,
                                                        width: hotV, height: yBot - yTop)))
                }
            }
            // Horizontal divider: a pane sits just below a's bottom edge.
            let bottomEdge = a.frame.maxY
            if bottomEdge < page.height - eps {
                let neighbors = frames.filter {
                    $0.frame.minY > bottomEdge - eps
                        && $0.frame.minY - bottomEdge < gapTolY
                        && xOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minY).min() {
                    let pos = (bottomEdge + nearest) / 2
                    let xL = neighbors.map { max($0.frame.minX, a.frame.minX) }.min() ?? a.frame.minX
                    let xR = neighbors.map { min($0.frame.maxX, a.frame.maxX) }.max() ?? a.frame.maxX
                    result.append(.init(paneID: a.id, vertical: false, position: pos,
                                        hotRect: CGRect(x: xL, y: pos - above,
                                                        width: xR - xL, height: above + below)))
                }
            }
        }
        return result
    }

    private func yOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat { min(a.maxY, b.maxY) - max(a.minY, b.minY) }
    private func xOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat { min(a.maxX, b.maxX) - max(a.minX, b.minX) }

    // MARK: - Title-drag swap / dock
    //
    // VS Code-style drop zones, exactly like the macOS host: hovering a
    // target pane previews the landing — its middle 50%×50% highlights the
    // WHOLE pane (drop = swap the two panes), the four edge bands highlight
    // that HALF (drop = re-split the target along that axis and dock the
    // dragged pane on that side).

    /// The pane + drop zone under a window-coordinate point, excluding the
    /// dragged pane. Pane frames live in `contentView`, so convert in first.
    private func dropTarget(atWindowPoint p: CGPoint, excluding source: PaneID)
        -> (pane: PaneID, zone: PaneDropZone)? {
        let local = contentView.convert(p, from: nil)
        guard let (id, vc) = paneControllers.first(where: { id, vc in
            id != source && !vc.view.isHidden && vc.view.frame.contains(local)
        }) else { return nil }
        return (id, PaneDropZone.zone(at: local, in: vc.view.frame))
    }

    private func handleTitleSwap(source paneID: PaneID, phase: TitleDragPhase) {
        // Rearranging only makes sense between visible tiles.
        guard !isFocusLayout else { return }
        switch phase {
        case .began:
            paneControllers[paneID]?.view.alpha = 0.6
        case .moved(let p):
            updateDropOverlay(dropTarget(atWindowPoint: p, excluding: paneID))
        case .ended(let p):
            let drop = dropTarget(atWindowPoint: p, excluding: paneID)
            endTitleDrag(paneID)
            guard let (target, zone) = drop else { return }
            if let dock = zone.dock {
                viewModel?.movePane(paneID, splitting: target,
                                    horizontal: dock.horizontal, before: dock.before)
            } else {
                viewModel?.swapPanes(paneID, with: target)
            }
        case .cancelled:
            endTitleDrag(paneID)
        }
    }

    private func endTitleDrag(_ paneID: PaneID) {
        paneControllers[paneID]?.view.alpha = 1.0
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
    }

    /// Show/move/hide the landing preview. The frame animates between zones
    /// and across panes while visible; appearing (or reappearing after a
    /// gap) snaps into place so the preview never slides in from a stale
    /// spot.
    private func updateDropOverlay(_ drop: (pane: PaneID, zone: PaneDropZone)?) {
        guard let drop, let paneFrame = paneControllers[drop.pane]?.view.frame else {
            dropOverlay?.isHidden = true
            return
        }
        let overlay: PaneDropZoneOverlayView
        let appearing: Bool
        if let existing = dropOverlay {
            overlay = existing
            appearing = overlay.isHidden
        } else {
            overlay = PaneDropZoneOverlayView()
            contentView.addSubview(overlay)   // above every pane view
            dropOverlay = overlay
            appearing = true
        }
        let target = drop.zone.highlightRect(in: paneFrame)
        overlay.isHidden = false
        overlay.zone = drop.zone
        if appearing {
            overlay.frame = target
        } else {
            UIView.animate(withDuration: 0.12) { overlay.frame = target }
        }
    }
}

/// The translucent landing preview shown while a pane drag hovers a target:
/// the whole pane for a center/swap drop (with a ⇄ badge — the one zone whose
/// meaning isn't its own shape), the docked half for an edge drop. Colored by
/// the inherited tint (the app accent, same as the focused-pane border).
/// Non-interactive; the title-bar pan owns the touch anyway.
final class PaneDropZoneOverlayView: UIView {
    private let icon = UIImageView(image: UIImage(
        systemName: "rectangle.2.swap",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)))

    var zone: PaneDropZone = .center {
        didSet { icon.isHidden = (zone != .center) }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.borderWidth = 2
        layer.cornerRadius = 6
        addSubview(icon)
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The real tint arrives when the view joins the hierarchy.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyTint()
    }

    private func applyTint() {
        backgroundColor = tintColor.withAlphaComponent(0.22)
        layer.borderColor = tintColor.cgColor
        icon.tintColor = tintColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.sizeToFit()
        icon.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}


// MARK: - Divider overlay (drag to resize)

/// A transparent overlay over the tiled panes. It is touch-transparent except
/// within a few points of a divider between two adjacent panes, where it
/// claims the touch to drag-resize them. Everywhere else, touches fall
/// through to the panes. iOS mirror of the macOS `DividerOverlay`.
final class TileDividerOverlay: UIView {
    /// A draggable boundary: the pane that owns it, orientation, and hot rect.
    struct Divider {
        let paneID: PaneID
        let vertical: Bool    // true = vertical line, drags left/right
        let position: CGFloat // x (vertical) or y (horizontal), in points
        let hotRect: CGRect
    }

    /// Touch grab sizes. Vertical dividers are CENTRED on the line.
    /// Horizontal dividers STRADDLE it — generous above (the upper pane's
    /// free surface) but only a little below, so the band sits on the border
    /// yet barely covers the lower pane's title bar (the drag-to-swap handle).
    static let hotThicknessV: CGFloat = 34
    static let hotAboveLine: CGFloat = 26
    static let hotBelowLine: CGFloat = 6

    var dividers: [Divider] = [] { didSet { setNeedsDisplay() } }
    /// Points per layout cell, set by the host so drag distance → cell delta.
    var pointsPerCell: CGPoint?
    /// (paneID, vertical, signed incremental cell delta) during a live drag.
    var onResize: ((PaneID, Bool, Int) -> Void)?

    private var dragDivider: Divider?
    private var dragStart: CGPoint = .zero
    private var dragSentCells = 0
    private var dragLivePos: CGFloat?

    private static let accent = UIColor(red: 0.20, green: 0.80, blue: 0.55, alpha: 1.0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func divider(at point: CGPoint) -> Divider? {
        dividers.first { $0.hotRect.contains(point) }
    }

    // Transparent except over a divider hot zone, so panes get all other touches.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        divider(at: point) != nil
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            let p = g.location(in: self)
            dragDivider = divider(at: p)
            dragStart = p
            dragSentCells = 0
            dragLivePos = dragDivider.map { $0.vertical ? p.x : p.y }
            setNeedsDisplay()
        case .changed:
            guard let d = dragDivider, let ppc = pointsPerCell else { return }
            let p = g.location(in: self)
            dragLivePos = d.vertical ? p.x : p.y
            setNeedsDisplay()
            let deltaPts = d.vertical ? (p.x - dragStart.x) : (p.y - dragStart.y)
            let perCell = d.vertical ? ppc.x : ppc.y
            guard perCell > 0 else { return }
            let totalCells = Int((deltaPts / perCell).rounded())
            let incremental = totalCells - dragSentCells
            guard incremental != 0 else { return }
            dragSentCells = totalCells
            onResize?(d.paneID, d.vertical, incremental)
        default:
            dragDivider = nil
            dragSentCells = 0
            dragLivePos = nil
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        for d in dividers {
            stroke(d, at: d.position, color: UIColor(white: 1, alpha: 0.30), width: 1.5)
        }
        // The line being dragged tracks the finger (the relayout lags), drawn
        // in the accent colour so the drag is clearly visible.
        if let d = dragDivider, let pos = dragLivePos {
            stroke(d, at: pos, color: Self.accent, width: 2)
        }
    }

    private func stroke(_ d: Divider, at pos: CGFloat, color: UIColor, width: CGFloat) {
        color.setStroke()
        let path = UIBezierPath()
        path.lineWidth = width
        if d.vertical {
            path.move(to: CGPoint(x: pos, y: d.hotRect.minY))
            path.addLine(to: CGPoint(x: pos, y: d.hotRect.maxY))
        } else {
            path.move(to: CGPoint(x: d.hotRect.minX, y: pos))
            path.addLine(to: CGPoint(x: d.hotRect.maxX, y: pos))
        }
        path.stroke()
    }
}

#endif
