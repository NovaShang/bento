import UIKit
import UIKit.UIGestureRecognizerSubclass

/// TWO-finger press-and-hold recognizer for Bento's hold-anywhere voice input —
/// the iOS twin of the Mac's right-click-hold (which a trackpad two-finger
/// press produces), so the mental model is one: "the second finger/button
/// means talk".
///
/// Why two fingers: the pane is a scrolly surface, and a single-finger hold is
/// structurally ambiguous against real scroll habits (rest a beat, then flick;
/// press, then scroll). No threshold fixes that — the gesture itself must be
/// one that scrolling never performs. Two fingers held still is exactly that:
/// single-finger scrolls, taps, and rests never involve a second finger, and a
/// two-finger pinch/pan moves immediately (which fails us via the slop check).
///
/// Why a custom recognizer instead of `UILongPressGestureRecognizer`:
/// - We want the full press → drag → release lifecycle in ONE recognizer so
///   zone tracking in `.changed` is unambiguous.
/// - We need to fail fast on movement during the arming window so scrolling
///   and pinching stay untouched.
/// - We fire prewarm/veto hooks at precise touch-down moments.
@MainActor
final class VoicePressGesture: UIGestureRecognizer {

    /// Time BOTH fingers must be down (mostly still) before we commit.
    var holdThreshold: TimeInterval = 0.18

    /// Centroid movement (in points) allowed during the arming window before we
    /// bail and let other recognizers (two-finger pan, pinch) take the touches.
    var slop: CGFloat = 10

    /// Fired the moment the SECOND finger lands — a voice hold just became
    /// plausible — before the hold threshold is evaluated. Used to prewarm the
    /// mic engine so a hold that becomes a recording starts capturing
    /// instantly. Cheap + idempotent, so firing on what turns out to be a
    /// pinch is harmless.
    var onTouchDown: (() -> Void)?

    /// Consulted when the second finger lands, BEFORE `onTouchDown` fires, so
    /// the host can veto arming from pre-touch state that `onTouchDown` itself
    /// mutates (e.g. an in-flight scroll fling). Returning false fails this
    /// recognizer for the whole touch.
    var shouldArm: (() -> Bool)?

    private var trackedTouches: [UITouch] = []
    private var startCentroid: CGPoint = .zero
    private var armTimer: Timer?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func reset() {
        super.reset()
        cancelArmTimer()
        trackedTouches = []
        startCentroid = .zero
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else { return }
        trackedTouches.append(contentsOf: touches)
        // Three fingers is some other gesture entirely.
        if trackedTouches.count > 2 {
            state = .failed
            return
        }
        guard trackedTouches.count == 2, view != nil else {
            // One finger down: wait quietly for a possible second. Scrolling is
            // unaffected (we neither delay nor cancel touches) — a moving or
            // lifting single finger fails us below.
            return
        }
        // Second finger landed → voice is now plausible.
        startCentroid = centroid()
        let vetoed = shouldArm?() == false
        onTouchDown?()
        if vetoed {
            state = .failed
            return
        }
        scheduleArmTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard view != nil, touches.contains(where: { trackedTouches.contains($0) }) else { return }
        switch state {
        case .possible:
            if trackedTouches.count < 2 {
                // Single finger moving = a scroll. Fail immediately so the pan
                // never waits on us.
                if let t = trackedTouches.first {
                    let loc = t.location(in: view)
                    let prev = t.previousLocation(in: view)
                    if abs(loc.x - prev.x) + abs(loc.y - prev.y) > 0 { state = .failed }
                }
                return
            }
            // Both down but still arming — real movement means pinch/two-finger
            // pan, not a hold.
            let c = centroid()
            let dx = c.x - startCentroid.x, dy = c.y - startCentroid.y
            if dx * dx + dy * dy > slop * slop {
                state = .failed
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.contains(where: { trackedTouches.contains($0) }) else { return }
        switch state {
        case .possible:
            // A finger lifted before the hold committed → not a hold.
            state = .failed
        case .began, .changed:
            // EITHER finger lifting is the release.
            state = .ended
        default:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.contains(where: { trackedTouches.contains($0) }) else { return }
        if state == .began || state == .changed {
            state = .cancelled
        } else {
            state = .failed
        }
    }

    // MARK: - Arm timer

    private func scheduleArmTimer() {
        cancelArmTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.state == .possible, self.trackedTouches.count == 2 else { return }
                // Commit. From here the touches belong to voice.
                self.cancelsTouchesInView = true
                self.state = .began
            }
        }
        armTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelArmTimer() {
        armTimer?.invalidate()
        armTimer = nil
    }

    /// Centroid of the live tracked touches in the recognizer's view
    /// coordinates — the "finger location" handlers anchor the panel to.
    func currentLocation() -> CGPoint {
        centroid()
    }

    private func centroid() -> CGPoint {
        guard let view, !trackedTouches.isEmpty else { return startCentroid }
        var x: CGFloat = 0, y: CGFloat = 0
        for t in trackedTouches {
            let p = t.location(in: view)
            x += p.x; y += p.y
        }
        let n = CGFloat(trackedTouches.count)
        return CGPoint(x: x / n, y: y / n)
    }
}
