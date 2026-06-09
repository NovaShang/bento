import UIKit
import SwiftUI
import BentoTerminalCore

/// Manages the voice input gesture + recording lifecycle.
/// Added to a pane's terminal view as a long-press gesture recognizer.
///
/// Flow: hold >200ms → start recording → move finger → direction detection →
///       release → inject text based on direction
///
/// Two speech engines are supported and chosen per-recording from the
/// `speech_engine` user setting:
/// - "apple":  on-device `SFSpeechRecognizer` (no API key, may have lower
///   accuracy / language coverage; requires speech-recognition permission).
/// - "openai": cloud OpenAI Realtime API with `gpt-realtime-whisper`
///   (requires either `openai_api_key` direct BYOK, or `openai_proxy_url`
///   pointing at a token-mint server).
@MainActor
final class VoiceInputController: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var activeDirection: VoiceDirection = .none
    @Published var showOverlay = false
    @Published var fingerScreenPosition: CGPoint = .zero

    /// Shared engine driver (engine selection + permissions + audio capture)
    /// lives in BentoTerminalCore so iOS + macOS run the same recording code.
    private let session = VoiceSession()

    private var holdOrigin: CGPoint = .zero
    private let directionThreshold: CGFloat = 40

    /// Called when voice input produces a result
    var onResult: ((VoiceInputResult) -> Void)?

    /// `VoiceInputResult` now lives in BentoTerminalCore; alias keeps existing
    /// `VoiceInputController.VoiceInputResult` references working.
    typealias VoiceInputResult = BentoTerminalCore.VoiceInputResult

    // MARK: - Tap-to-Toggle (mic button)

    /// Tap-to-toggle recording, anchored at a screen point (used for overlay
    /// placement). First tap starts recording; second tap stops + submits the
    /// transcript with no directional modifier (plain text inject).
    func toggleRecording(anchorScreenPoint: CGPoint) {
        if isRecording {
            stopRecording(direction: .none)
        } else {
            fingerScreenPosition = anchorScreenPoint
            holdOrigin = anchorScreenPoint
            startRecording()
        }
    }

    // MARK: - Gesture Handling

    func handleLongPress(state: UIGestureRecognizer.State, location: CGPoint) {
        switch state {
        case .began:
            // Anchor the compass overlay at the press origin and keep it there.
            // The compass's center "finger dot" + 4 directional arrows are laid
            // out at fixed offsets, so the whole thing must NOT track the
            // finger — otherwise the arrows move with the user and can never
            // be reached. Direction feedback is conveyed by highlighting the
            // active arrow, not by moving the overlay.
            holdOrigin = location
            fingerScreenPosition = location
            startRecording()

        case .changed:
            updateDirection(currentLocation: location)

        case .ended, .cancelled:
            let finalDirection = activeDirection
            stopRecording(direction: finalDirection)

        default:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        // Show overlay immediately for responsiveness.
        isRecording = true
        showOverlay = true
        transcript = ""
        activeDirection = .none
        HapticService.shared.prepare()
        HapticService.shared.recordingStarted()
        // The shared VoiceSession handles permissions + engine selection + audio.
        session.start(
            onPartial: { [weak self] text in self?.transcript = text },
            onError: { [weak self] message in Task { await self?.showTransientError(message) } })
    }

    private func showTransientError(_ message: String) async {
        dlog(message)
        // Release the mic engine + ASR on error so a failed session can't leave a
        // running engine that the next recording stacks a second tap onto.
        _ = session.stop()
        transcript = message
        isRecording = false
        try? await Task.sleep(for: .milliseconds(1200))
        showOverlay = false
    }

    // MARK: - Stop

    private func stopRecording(direction: VoiceDirection) {
        let finalText = session.stop()
        isRecording = false

        if direction == .down {
            HapticService.shared.cancelled()
            showOverlay = false
            return
        }

        if !finalText.isEmpty {
            HapticService.shared.sent()
            onResult?(VoiceInputResult(text: finalText, direction: direction))
        }

        showOverlay = false
    }

    // MARK: - Direction Detection

    private func updateDirection(currentLocation: CGPoint) {
        let dx = currentLocation.x - holdOrigin.x
        let dy = currentLocation.y - holdOrigin.y

        let newDirection: VoiceDirection
        if abs(dx) < directionThreshold && abs(dy) < directionThreshold {
            newDirection = .none
        } else if abs(dx) > abs(dy) {
            newDirection = dx > 0 ? .right : .left
        } else {
            newDirection = dy < 0 ? .up : .down
        }

        if newDirection != activeDirection {
            activeDirection = newDirection
            if newDirection != .none {
                HapticService.shared.directionChanged()
            }
        }
    }
}

// `TerminalViewModel.handleVoiceResult(_:)` now lives in BentoTerminalCore
// (shared by iOS + macOS).
