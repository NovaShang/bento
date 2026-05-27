import UIKit
import SwiftTmux

/// Unified gesture coordinator for the terminal canvas.
///
/// Architecture:
/// - Per-pane "selection" tap is installed as a passive recognizer on each
///   TerminalView. It does NOT cancel touches and runs simultaneously with
///   every SwiftTerm gesture, so native long-press text selection, double-tap
///   word select, triple-tap line select, scroll, and edit menu all keep
///   working. The passive tap only signals "user touched this pane" so we
///   can mark it active. Keyboard focus is left to SwiftTerm's own tap path.
/// - Canvas-level gestures (divider drag, empty-area taps) use a transparent
///   overlay that only intercepts touches NOT on panes.
@MainActor
final class GestureCoordinator: NSObject {

    // MARK: - Dependencies

    weak var voiceController: VoiceInputController?

    // MARK: - Callbacks

    var onSelectPane: ((TmuxPaneID) -> Void)?
    var onFocusPane: ((TmuxPaneID) -> Void)?
    var onExitFocus: (() -> Void)?
    var onFitToScreen: (() -> Void)?
    var onDismissKeyboard: (() -> Void)?
    var onResizePane: ((TmuxPaneID, String, Int) -> Void)?

    /// Pane lookup: returns (paneID, terminalContainerVC) at a canvas point
    var paneAt: ((CGPoint) -> (TmuxPaneID, TerminalContainerVC)?)?

    /// Returns all pane frames (paneID → frame in canvas coords)
    var allPaneFrames: (() -> [(TmuxPaneID, CGRect)])?

    /// Cell size in points
    var cellSize: CGSize = CGSize(width: 8, height: 16)

    var isInFocusMode: () -> Bool = { false }

    // MARK: - Canvas Overlay (for empty-area taps + divider drag)

    private let overlay = CanvasOverlay()

    /// Debug: when true, paint the divider hit-test zones as translucent
    /// bands so you can verify how generous the touch target really is.
    /// The bands are `isUserInteractionEnabled = false`, so they do not
    /// intercept any touches themselves.
    var debugShowDividerZones: Bool = true {
        didSet { refreshDebugDividerZones() }
    }
    private var debugZoneViews: [UIView] = []

    func install(on canvasView: UIView) {
        overlay.coordinator = self
        overlay.frame = canvasView.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.addSubview(overlay)

        // Tap on empty canvas area
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        tap.delegate = self
        overlay.addGestureRecognizer(tap)

        // Double-tap on empty canvas area → fit to screen
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        overlay.addGestureRecognizer(doubleTap)

        // Pan for divider drag (only begins near dividers)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDividerPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        overlay.addGestureRecognizer(pan)
    }

    func updateOverlayFrame(_ frame: CGRect) {
        overlay.frame = frame
        refreshDebugDividerZones()
    }

    func bringOverlayToFront() {
        overlay.superview?.bringSubviewToFront(overlay)
    }

    // MARK: - Per-Pane Gesture Setup

    /// Attach per-pane gestures to a TerminalContainerVC.
    ///
    /// Two recognizers go on each TerminalView:
    /// 1. A passive selection tap (marks the pane active; runs alongside every
    ///    SwiftTerm gesture without canceling them).
    /// 2. A `VoicePressGesture` that owns single-finger long-press for voice
    ///    input. Every recognizer SwiftTerm installed (its singleTap that
    ///    calls becomeFirstResponder, its selection long-press, double/triple-
    ///    tap) is forced to wait for ours to fail via `require(toFail:)`.
    ///    Quick taps and flicks fail our recognizer almost instantly, so
    ///    SwiftTerm's behavior is unaffected — but a sustained hold cancels
    ///    them all and voice claims the touch.
    func attachPaneGestures(to vc: TerminalContainerVC, paneID: TmuxPaneID) {
        let tv = vc.terminalView!

        // Snapshot SwiftTerm's recognizers before we add ours.
        let preExisting = tv.gestureRecognizers ?? []

        let tap = UITapGestureRecognizer(target: self, action: #selector(self.handlePaneTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        tap.accessibilityLabel = paneID.description
        tv.addGestureRecognizer(tap)

        let voicePress = VoicePressGesture(target: self, action: #selector(self.handleVoicePress(_:)))
        voicePress.delegate = self
        voicePress.accessibilityLabel = paneID.description
        tv.addGestureRecognizer(voicePress)

        for other in preExisting {
            other.require(toFail: voicePress)
        }
    }

    // MARK: - Pane Gesture Handlers

    @objc private func handlePaneTap(_ gesture: UITapGestureRecognizer) {
        guard let paneID = paneIDFrom(gesture) else { return }
        onSelectPane?(paneID)
    }

    @objc private func handleVoicePress(_ gesture: VoicePressGesture) {
        guard let controller = voiceController, let view = gesture.view else { return }
        if let paneID = paneIDFrom(gesture) {
            onSelectPane?(paneID)
        }
        // VoiceInputController works in screen (window-nil) coordinates because
        // the SwiftUI overlay positions itself with .position(...) in that space.
        let local = gesture.currentLocation()
        let screen = view.convert(local, to: nil)
        controller.handleLongPress(state: gesture.state, location: screen)
    }

    private func paneIDFrom(_ gesture: UIGestureRecognizer) -> TmuxPaneID? {
        guard let raw = gesture.accessibilityLabel else { return nil }
        return TmuxPaneID(string: raw)
    }

    // MARK: - Canvas Gesture Handlers

    @objc private func handleCanvasTap(_ gesture: UITapGestureRecognizer) {
        if isInFocusMode() {
            onExitFocus?()
        } else {
            // Empty canvas tap always dismisses any active first responder
            // (the on-screen keyboard). No-op if nothing is focused.
            onDismissKeyboard?()
        }
    }

    @objc private func handleCanvasDoubleTap(_ gesture: UITapGestureRecognizer) {
        if isInFocusMode() {
            onExitFocus?()
        } else {
            onFitToScreen?()
        }
    }

    // MARK: - Divider Drag

    private var isDraggingDivider = false
    private var dividerAxis: DividerAxis = .vertical
    private var dividerPaneID: TmuxPaneID?
    private var dividerOrigin: CGFloat = 0
    private var dividerSpan: (CGFloat, CGFloat) = (0, 0)
    private var totalDragDelta: CGFloat = 0
    private var ghostLine: UIView?
    private var ghostAreaA: UIView?
    private var ghostAreaB: UIView?

    enum DividerAxis { case vertical, horizontal }

    @objc private func handleDividerPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let point = gesture.location(in: overlay)
            guard let (paneID, axis, origin, span) = findDividerInfo(at: point) else { return }
            isDraggingDivider = true
            dividerPaneID = paneID
            dividerAxis = axis
            dividerOrigin = origin
            dividerSpan = span
            totalDragDelta = 0
            showGhost(axis: axis, position: origin, span: span)

        case .changed:
            guard isDraggingDivider else { return }
            let translation = gesture.translation(in: overlay)
            gesture.setTranslation(.zero, in: overlay)
            let delta = dividerAxis == .vertical ? translation.x : translation.y
            totalDragDelta += delta
            let cellDim = dividerAxis == .vertical ? cellSize.width : cellSize.height
            let snappedDelta = round(totalDragDelta / cellDim) * cellDim
            updateGhost(axis: dividerAxis, position: dividerOrigin + snappedDelta, span: dividerSpan)

        case .ended:
            guard isDraggingDivider, let paneID = dividerPaneID else { return }
            let cellDim = dividerAxis == .vertical ? cellSize.width : cellSize.height
            let cells = Int(round(totalDragDelta / cellDim))
            if cells != 0 {
                let dir = dividerAxis == .vertical
                    ? (cells > 0 ? "R" : "L")
                    : (cells > 0 ? "D" : "U")
                onResizePane?(paneID, dir, abs(cells))
            }
            hideGhost()
            isDraggingDivider = false
            dividerPaneID = nil

        case .cancelled:
            hideGhost()
            isDraggingDivider = false
            dividerPaneID = nil

        default: break
        }
    }

    /// Half-width (in points) of the divider drag hit-test band.
    static let dividerHitHalfWidth: CGFloat = 12

    func findDividerInfo(at point: CGPoint) -> (TmuxPaneID, DividerAxis, CGFloat, (CGFloat, CGFloat))? {
        guard let frames = allPaneFrames?() else { return nil }
        let threshold = Self.dividerHitHalfWidth
        for (paneID, frame) in frames {
            if abs(point.x - frame.maxX) < threshold && point.y > frame.minY && point.y < frame.maxY {
                return (paneID, .vertical, frame.maxX, (frame.minY, frame.maxY))
            }
            if abs(point.y - frame.maxY) < threshold && point.x > frame.minX && point.x < frame.maxX {
                return (paneID, .horizontal, frame.maxY, (frame.minX, frame.maxX))
            }
        }
        return nil
    }

    // MARK: - Debug Divider Zone Visualization

    private func refreshDebugDividerZones() {
        for v in debugZoneViews { v.removeFromSuperview() }
        debugZoneViews.removeAll()

        guard debugShowDividerZones, let frames = allPaneFrames?() else { return }

        let canvasSize = overlay.bounds.size
        let half = Self.dividerHitHalfWidth
        // findDividerInfo strict inequality is `> minY` / `< maxY`, so the
        // band is mathematically open on the boundary cells. For
        // visualization we use the same bbox, that's close enough.
        for (_, frame) in frames {
            // Vertical band on the pane's right edge — only if there's
            // actually a neighbor on the other side (not the canvas edge).
            if frame.maxX < canvasSize.width - 0.5 {
                let band = makeDebugBand(color: .systemRed)
                band.frame = CGRect(
                    x: frame.maxX - half,
                    y: frame.minY,
                    width: half * 2,
                    height: frame.height
                )
                overlay.addSubview(band)
                debugZoneViews.append(band)
            }
            // Horizontal band on the pane's bottom edge.
            if frame.maxY < canvasSize.height - 0.5 {
                let band = makeDebugBand(color: .systemBlue)
                band.frame = CGRect(
                    x: frame.minX,
                    y: frame.maxY - half,
                    width: frame.width,
                    height: half * 2
                )
                overlay.addSubview(band)
                debugZoneViews.append(band)
            }
        }
    }

    private func makeDebugBand(color: UIColor) -> UIView {
        let v = UIView()
        v.backgroundColor = color.withAlphaComponent(0.22)
        v.layer.borderColor = color.withAlphaComponent(0.7).cgColor
        v.layer.borderWidth = 0.5
        v.isUserInteractionEnabled = false
        return v
    }

    // MARK: - Ghost Preview

    private func showGhost(axis: DividerAxis, position: CGFloat, span: (CGFloat, CGFloat)) {
        guard let canvas = overlay.superview else { return }
        let line = UIView()
        line.backgroundColor = UIColor.tintColor
        line.alpha = 0.8
        let areaA = UIView()
        areaA.backgroundColor = UIColor.tintColor.withAlphaComponent(0.08)
        let areaB = UIView()
        areaB.backgroundColor = UIColor.tintColor.withAlphaComponent(0.08)
        canvas.addSubview(areaA)
        canvas.addSubview(areaB)
        canvas.addSubview(line)
        ghostLine = line; ghostAreaA = areaA; ghostAreaB = areaB
        updateGhost(axis: axis, position: position, span: span)
        overlay.superview?.bringSubviewToFront(overlay)
    }

    private func updateGhost(axis: DividerAxis, position: CGFloat, span: (CGFloat, CGFloat)) {
        guard let canvas = overlay.superview else { return }
        let s = canvas.bounds.size
        switch axis {
        case .vertical:
            ghostLine?.frame = CGRect(x: position - 1, y: span.0, width: 2, height: span.1 - span.0)
            ghostAreaA?.frame = CGRect(x: 0, y: span.0, width: position, height: span.1 - span.0)
            ghostAreaB?.frame = CGRect(x: position, y: span.0, width: s.width - position, height: span.1 - span.0)
        case .horizontal:
            ghostLine?.frame = CGRect(x: span.0, y: position - 1, width: span.1 - span.0, height: 2)
            ghostAreaA?.frame = CGRect(x: span.0, y: 0, width: span.1 - span.0, height: position)
            ghostAreaB?.frame = CGRect(x: span.0, y: position, width: span.1 - span.0, height: s.height - position)
        }
    }

    private func hideGhost() {
        ghostLine?.removeFromSuperview(); ghostAreaA?.removeFromSuperview(); ghostAreaB?.removeFromSuperview()
        ghostLine = nil; ghostAreaA = nil; ghostAreaB = nil
    }
}

// MARK: - UIGestureRecognizerDelegate

extension GestureCoordinator: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // VoicePressGesture is mutually exclusive with SwiftTerm's selection
        // long-press (covered by require(toFail:) in attachPaneGestures).
        // For everything else it can coexist — but in practice, single-tap and
        // double/triple-tap will already have failed by the time we commit at
        // 180ms because they require us to fail first.
        if gestureRecognizer is VoicePressGesture {
            return !(other is UILongPressGestureRecognizer)
        }
        // The pane-selection tap must run alongside EVERY native SwiftTerm
        // gesture (tap, long-press text select, double/triple-tap, scroll).
        // Returning true unconditionally for our tap is the simplest correct
        // policy — we are a passive observer that doesn't cancel touches.
        if gestureRecognizer is UITapGestureRecognizer { return true }
        // Two-finger scrollView pan + pinch should also coexist with our
        // canvas gestures (overlay tap, divider pan).
        if other is UIPinchGestureRecognizer { return true }
        if let pan = other as? UIPanGestureRecognizer, pan.minimumNumberOfTouches >= 2 { return true }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Divider pan vetting happens in shouldReceive(touch:) using the
        // INITIAL touch location. `pan.location(in:)` here would be the
        // current finger position after the system has detected enough
        // movement to start the pan — which is usually already outside the
        // hit zone, breaking drags that start in-zone but move outward.
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view is UIButton || touch.view is UIControl { return false }
        // Divider pan: only accept the touch if the FIRST contact landed
        // within the hit zone. Once accepted, the pan can drag anywhere.
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view === overlay {
            let p = touch.location(in: overlay)
            return findDividerInfo(at: p) != nil
        }
        return true
    }
}

// MARK: - Canvas Overlay

/// Sits on top of canvasView but ONLY intercepts touches on empty areas and dividers.
/// Touches on pane views pass through — SwiftTerm handles scroll/selection natively.
private final class CanvasOverlay: UIView {
    weak var coordinator: GestureCoordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let canvasView = superview else { return nil }

        // Check if point is on a UIButton in a sibling pane view
        for sibling in canvasView.subviews where sibling !== self {
            let siblingPoint = sibling.convert(point, from: self)
            if let hit = sibling.hitTest(siblingPoint, with: event),
               hit is UIButton || hit is UIControl {
                return hit
            }
        }

        // Check if point is near a divider → overlay handles it
        if coordinator?.findDividerInfo(at: point) != nil {
            return self
        }

        // Check if point is on a pane → let the pane's TerminalView handle it
        for sibling in canvasView.subviews where sibling !== self {
            let siblingPoint = sibling.convert(point, from: self)
            if sibling.point(inside: siblingPoint, with: event) {
                // Pass through to the pane — our per-pane gestures on TerminalView handle taps/long-press
                return sibling.hitTest(siblingPoint, with: event)
            }
        }

        // Empty canvas area → overlay handles tap/double-tap
        return self
    }
}

// MARK: - SwiftTerm import for TerminalView type
import SwiftTerm
