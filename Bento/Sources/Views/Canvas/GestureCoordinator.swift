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
    }

    func bringOverlayToFront() {
        overlay.superview?.bringSubviewToFront(overlay)
    }

    // MARK: - Per-Pane Gesture Setup

    /// Attach per-pane gestures to a TerminalContainerVC.
    ///
    /// Policy for each SwiftTerm-installed recognizer:
    /// - Single-tap (numberOfTapsRequired == 1): **DISABLED**. It was the
    ///   keyboard-shower (calls becomeFirstResponder) and triggered too
    ///   easily. Keyboard now comes from an explicit toolbar button.
    /// - Long-press selection: required to fail by voice press — voice wins
    ///   at 180ms, SwiftTerm's ~500ms selection never gets a chance.
    /// - Multi-tap (double/triple-tap word/line select): required to fail by
    ///   voice press. No real lag — the first tap-lift instantly fails ours.
    /// - Pan / scroll: **left alone**. We do NOT make scroll wait on voice;
    ///   the recognizers race, and any deliberate drag past the pan
    ///   threshold (~10pt) wins because our voice fails on slop (6pt) first.
    /// - Pinch / two-finger pan: untouched.
    func attachPaneGestures(to vc: TerminalContainerVC, paneID: TmuxPaneID) {
        let tv = vc.terminalView!

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
            if let t = other as? UITapGestureRecognizer, t.numberOfTapsRequired == 1 {
                // Kill SwiftTerm's singleTap → no more accidental keyboard / link
                // click on every tap. Keyboard comes from the toolbar button.
                t.isEnabled = false
            } else if other is UILongPressGestureRecognizer || other is UITapGestureRecognizer {
                other.require(toFail: voicePress)
            }
            // Pan / pinch / everything else: untouched, so scroll feels live.
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

    /// Initial touch location captured by `shouldReceive(touch:)`. Used by
    /// `.began` to identify the divider — by the time `.began` fires the pan
    /// has already moved ~10pt past the initial touch and may be outside the
    /// hit zone, so re-running findDividerInfo on the current location was
    /// the reason most drag attempts failed.
    private var dividerPanInitialPoint: CGPoint?

    enum DividerAxis { case vertical, horizontal }

    @objc private func handleDividerPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // Use the touch's INITIAL location (captured at touchesBegan in
            // shouldReceive), not the current location — the pan has already
            // moved ~10pt to reach .began and may be outside the divider hit
            // band.
            let point = dividerPanInitialPoint ?? gesture.location(in: overlay)
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
            dividerPanInitialPoint = nil

        case .cancelled:
            hideGhost()
            isDraggingDivider = false
            dividerPaneID = nil
            dividerPanInitialPoint = nil

        default: break
        }
    }

    /// Half-width (in points) of the divider drag hit-test band. Total band
    /// is `2 × half = 44pt`, matching Apple HIG's 44pt minimum touch target so
    /// the divider is grabbable on a finger pad without precision aim. The
    /// pane interior past this band still passes touches to SwiftTerm (text
    /// selection / scroll), so the cost of being generous is small.
    static let dividerHitHalfWidth: CGFloat = 22

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
        // We capture the initial point here so .began can use it instead of
        // re-hit-testing the (already moved) current location.
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view === overlay {
            let p = touch.location(in: overlay)
            guard findDividerInfo(at: p) != nil else { return false }
            dividerPanInitialPoint = p
            return true
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
