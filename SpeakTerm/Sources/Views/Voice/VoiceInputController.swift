import UIKit
import SwiftUI
import AVFoundation

/// Manages the voice input gesture + recording lifecycle.
/// Added to a pane's terminal view as a long-press gesture recognizer.
///
/// Flow: hold >200ms → start recording → move finger → direction detection →
///       release → inject text based on direction
@MainActor
final class VoiceInputController: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var activeDirection: VoiceDirection = .none
    @Published var showOverlay = false

    private nonisolated(unsafe) let speechEngine: any SpeechEngine = AppleSpeechEngine()
    private var holdOrigin: CGPoint = .zero
    private let directionThreshold: CGFloat = 40
    private var isAuthorized = false

    /// Called when voice input produces a result
    var onResult: ((VoiceInputResult) -> Void)?

    struct VoiceInputResult {
        let text: String
        let direction: VoiceDirection
    }

    // MARK: - Gesture Handling

    func handleLongPress(state: UIGestureRecognizer.State, location: CGPoint) {
        switch state {
        case .began:
            holdOrigin = location
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
        // Request permissions on first use
        if !isAuthorized {
            Task {
                let speechOK = await AppleSpeechEngine.requestAuthorization()
                let micOK = await withCheckedContinuation { cont in
                    AVAudioApplication.requestRecordPermission { granted in
                        cont.resume(returning: granted)
                    }
                }
                if speechOK && micOK {
                    isAuthorized = true
                    beginRecording()
                } else {
                    dlog("Speech/mic permission denied")
                    isRecording = false
                    showOverlay = false
                }
            }
            // Show overlay optimistically while awaiting permission
            isRecording = true
            showOverlay = true
            transcript = ""
            activeDirection = .none
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        HapticService.shared.prepare()
        HapticService.shared.recordingStarted()

        isRecording = true
        showOverlay = true
        transcript = ""
        activeDirection = .none

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.speechEngine.startRecording { partial in
                    Task { @MainActor in
                        self.transcript = partial
                    }
                }
            } catch {
                dlog("Speech recording error: \(error)")
                await MainActor.run {
                    self.isRecording = false
                    self.showOverlay = false
                }
            }
        }
    }

    private func stopRecording(direction: VoiceDirection) {
        let finalText = speechEngine.stopRecording() ?? transcript
        isRecording = false

        if direction == .down {
            // Cancel
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
