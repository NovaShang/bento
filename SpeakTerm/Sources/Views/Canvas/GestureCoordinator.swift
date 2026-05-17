import UIKit
import SwiftTmux

/// Unified gesture coordinator for the terminal canvas.
///
/// Architecture:
/// - Per-pane gestures (tap, long-press) are added to each TerminalView directly
///   so SwiftTerm's native scroll and selection still work
/// - Canvas-level gestures (divider drag, empty-area taps) use a transparent overlay
///   that only intercepts touches NOT on panes
@MainActor
final class GestureCoordinator: NSObject {

    // MARK: - Dependencies

    var getInputMode: () -> InputMode = { .voice }
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

    /// Call this for each TerminalContainerVC to add pane-level gestures.
    /// Disables SwiftTerm's long-press/edit menu, keeps scroll and selection.
    /// Must be called after a tick so SwiftTerm's own gestures are installed.
    func attachPaneGestures(to vc: TerminalContainerVC, paneID: TmuxPaneID) {
        // Delay so SwiftTerm has finished installing its own gestures
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let tv = vc.terminalView!

            // Disable only SwiftTerm's long-press and edit menu interaction
            for recognizer in tv.gestureRecognizers ?? [] {
                if recognizer is UILongPressGestureRecognizer {
                    recognizer.isEnabled = false
                }
            }
            for interaction in tv.interactions {
                if interaction is UIEditMenuInteraction {
                    tv.removeInteraction(interaction)
                }
            }

            // Add our tap → select pane (+ keyboard in keyboard mode)
            let tap = UITapGestureRecognizer(target: self, action: #selector(self.handlePaneTap(_:)))
            tap.delegate = self
            tap.accessibilityLabel = paneID.description
            tv.addGestureRecognizer(tap)

            // Add our long press → voice input
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(self.handlePaneLongPress(_:)))
            longPress.minimumPressDuration = 0.3
            longPress.delegate = self
            longPress.accessibilityLabel = paneID.description
            tv.addGestureRecognizer(longPress)

            // Our tap should not block SwiftTerm's double-tap (text selection)
            for existing in tv.gestureRecognizers ?? [] where existing !== tap && existing !== longPress {
                if let existingTap = existing as? UITapGestureRecognizer, existingTap.numberOfTapsRequired == 2 {
                    tap.require(toFail: existingTap)
                }
            }
        }
    }

    // MARK: - Pane Gesture Handlers

    @objc private func handlePaneTap(_ gesture: UITapGestureRecognizer) {
        guard let paneID = paneIDFrom(gesture) else { return }
        let mode = getInputMode()

        onSelectPane?(paneID)
        if mode == .keyboard, let tv = gesture.view as? TerminalView {
            tv.becomeFirstResponder()
        }
    }

    @objc private func handlePaneLongPress(_ gesture: UILongPressGestureRecognizer) {
        let mode = getInputMode()
        guard mode == .voice else { return }

        let point = gesture.location(in: overlay)

        switch gesture.state {
        case .began:
            if let paneID = paneIDFrom(gesture) {
                onSelectPane?(paneID)
            }
            if let window = gesture.view?.window {
                let screenPoint = gesture.location(in: window)
                voiceController?.fingerScreenPosition = screenPoint
            }
            voiceController?.handleLongPress(state: .began, location: point)
        case .changed:
            voiceController?.handleLongPress(state: .changed, location: gesture.location(in: overlay))
        case .ended:
            voiceController?.handleLongPress(state: .ended, location: gesture.location(in: overlay))
        case .cancelled:
            voiceController?.handleLongPress(state: .cancelled, location: gesture.location(in: overlay))
        default: break
        }
    }

    private func paneIDFrom(_ gesture: UIGestureRecognizer) -> TmuxPaneID? {
        guard let raw = gesture.accessibilityLabel else { return nil }
        return TmuxPaneID(string: raw)
    }

    // MARK: - Canvas Gesture Handlers

    @objc private func handleCanvasTap(_ gesture: UITapGestureRecognizer) {
        let mode = getInputMode()
        if isInFocusMode() {
            onExitFocus?()
        } else if mode == .keyboard {
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

    func findDividerInfo(at point: CGPoint) -> (TmuxPaneID, DividerAxis, CGFloat, (CGFloat, CGFloat))? {
        guard let frames = allPaneFrames?() else { return nil }
        let threshold: CGFloat = 12
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
        // Allow pinch and two-finger pan from scrollView
        if other is UIPinchGestureRecognizer { return true }
        if let pan = other as? UIPanGestureRecognizer, pan.minimumNumberOfTouches >= 2 { return true }
        // Our pane tap should not block SwiftTerm's pan (scroll)
        if gestureRecognizer is UITapGestureRecognizer && other is UIPanGestureRecognizer { return true }
        // Our long press should not block SwiftTerm's pan (scroll)
        if gestureRecognizer is UILongPressGestureRecognizer && other is UIPanGestureRecognizer { return true }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Divider pan: only begin near a divider
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view === overlay {
            return findDividerInfo(at: pan.location(in: overlay)) != nil
        }
        // Long press only begins in voice mode — prevents stealing touches in keyboard mode
        if gestureRecognizer is UILongPressGestureRecognizer && gestureRecognizer.view !== overlay {
            return getInputMode() == .voice
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view is UIButton || touch.view is UIControl { return false }
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
