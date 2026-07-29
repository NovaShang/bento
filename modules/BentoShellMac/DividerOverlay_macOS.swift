#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import BentoAgentPane
import AppKit

// MARK: - Divider overlay (drag to resize)

/// A transparent overlay covering the whole host. It is hit-test-transparent
/// except within a few points of a divider between two adjacent panes, where it
/// claims the mouse to drag-resize (and shows a resize cursor). Everywhere else
/// clicks fall through to the panes.
@MainActor
final class DividerOverlay: NSView {
    weak var host: TiledPaneHost?

    /// A draggable boundary: the pane that owns it, orientation, and hot rect.
    private struct Divider {
        let paneID: PaneID
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
        let lineColor = PaneChromeColors.isDark
            ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.18)
        for d in dividers {
            strokeLine(vertical: d.vertical, at: d.position, span: d.hotRect,
                       color: lineColor, width: 1)
        }
        // The line being dragged tracks the cursor live (the relayout lags
        // behind), drawn in the accent colour so the drag is clearly visible.
        if let d = dragDivider, let pos = dragLivePos {
            strokeLine(vertical: d.vertical, at: pos, span: d.hotRect,
                       color: PaneChromeColors.accentNSColor, width: 2)
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
        // layout divider column), so neighbours don't share a coincident edge.
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

    /// Points per session cell along each axis (proportional tiling = bounds / grid).
    private func pointsPerCell() -> CGPoint? {
        guard let host, bounds.width > 0, bounds.height > 0 else { return nil }
        let grid = host.paneGridSize
        guard grid.cols > 0, grid.rows > 0 else { return nil }
        return CGPoint(x: bounds.width / grid.cols, y: bounds.height / grid.rows)
    }
}

#endif
