import UIKit

/// Unified gesture coordinator for the terminal canvas.
///
/// Owns ALL gesture recognition and dispatches actions based on:
/// - Input mode (voice vs keyboard)
/// - Touch location (pane vs empty canvas vs title bar)
/// - Touch timing (tap vs hold vs drag)
///
/// Attached to a transparent overlay view on top of the scrollView's canvasView.
/// Multi-touch (pinch/pan) passes through to the scrollView.
/// Single-touch is fully managed here.
@MainActor
final class GestureCoordinator: NSObject {

    // MARK: - Dependencies

    /// Returns current input mode
    var getInputMode: () -> InputMode = { .voice }

    /// Voice controller for long-press recording
    weak var voiceController: VoiceInputController?

    // MARK: - Callbacks

    var onSelectPane: ((TmuxPaneID) -> Void)?
    var onFocusPane: ((TmuxPaneID) -> Void)?
    var onExitFocus: (() -> Void)?
    var onFitToScreen: (() -> Void)?
    var onDismissKeyboard: (() -> Void)?

    /// Pane lookup: returns (paneID, terminalContainerVC) at a canvas point
    var paneAt: ((CGPoint) -> (TmuxPaneID, TerminalContainerVC)?)?

    /// Whether we're in focus mode
    var isInFocusMode: () -> Bool = { false }

    // MARK: - The Overlay

    private let overlay = GestureOverlay()

    /// Install the overlay on top of the given canvasView, within the scrollView.
    /// The overlay sits in the same coordinate space as canvasView.
    func install(on canvasView: UIView) {
        overlay.coordinator = self
        overlay.frame = canvasView.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.addSubview(overlay)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.delegate = self

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self

        // Note: NOT requiring tap to fail doubleTap — this avoids 300ms delay on pane selection.
        // Double-tap fires independently; the extra pane-select from single-tap is harmless.

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.2
        longPress.delegate = self

        overlay.addGestureRecognizer(tap)
        overlay.addGestureRecognizer(doubleTap)
        overlay.addGestureRecognizer(longPress)
    }

    /// Update overlay frame (call from layoutPanes)
    func updateOverlayFrame(_ frame: CGRect) {
        overlay.frame = frame
    }

    /// Ensure overlay stays on top after pane views are added
    func bringOverlayToFront() {
        overlay.superview?.bringSubviewToFront(overlay)
    }

    // MARK: - Gesture Handlers

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: overlay)
        let mode = getInputMode()

        if let (paneID, vc) = paneAt?(point) {
            // Tap on a pane
            onSelectPane?(paneID)
            if mode == .keyboard {
                vc.terminalView.becomeFirstResponder()
            }
            // Voice mode: no keyboard (don't becomeFirstResponder)
        } else {
            // Tap on empty canvas area
            if mode == .keyboard {
                onDismissKeyboard?()
            }
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: overlay)

        if isInFocusMode() {
            onExitFocus?()
            return
        }

        if paneAt?(point) != nil {
            // Double-tap on pane: let SwiftTerm handle word selection
            // (we don't intercept this — it passes through the overlay)
            return
        }

        // Double-tap on empty area: fit to screen
        onFitToScreen?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let mode = getInputMode()
        guard mode == .voice else { return }

        let point = gesture.location(in: overlay)

        switch gesture.state {
        case .began:
            if let (paneID, _) = paneAt?(point) {
                onSelectPane?(paneID)
            }
            voiceController?.handleLongPress(state: .began, location: point)

        case .changed:
            voiceController?.handleLongPress(state: .changed, location: gesture.location(in: overlay))

        case .ended:
            voiceController?.handleLongPress(state: .ended, location: gesture.location(in: overlay))

        case .cancelled:
            voiceController?.handleLongPress(state: .cancelled, location: gesture.location(in: overlay))

        default:
            break
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension GestureCoordinator: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow pinch and two-finger pan from scrollView to work alongside our gestures
        if otherGestureRecognizer is UIPinchGestureRecognizer { return true }
        if let pan = otherGestureRecognizer as? UIPanGestureRecognizer,
           pan.minimumNumberOfTouches >= 2 { return true }
        // Don't allow our tap to fire simultaneously with SwiftTerm's tap
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Don't intercept if touch is on a UIButton (title bar focus button)
        if touch.view is UIButton || touch.view is UIControl { return false }
        return true
    }
}

// MARK: - Gesture Overlay View

/// Transparent view that sits on top of the canvas.
/// For single-touch: our gesture recognizers handle it.
/// For multi-touch: passes through to scrollView for pinch/pan.
private final class GestureOverlay: UIView {
    weak var coordinator: GestureCoordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Let UIButton taps pass through (title bar ⛶ button)
        let hit = super.hitTest(point, with: event)
        if hit is UIButton || hit is UIControl { return hit }
        // For everything else, return self to capture touches
        return self
    }

    // Forward multi-touch to scrollView (superview chain)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first, touch.tapCount == 0 || touches.count > 1 {
            next?.touchesBegan(touches, with: event)
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        next?.touchesMoved(touches, with: event)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        next?.touchesEnded(touches, with: event)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        next?.touchesCancelled(touches, with: event)
        super.touchesCancelled(touches, with: event)
    }
}
