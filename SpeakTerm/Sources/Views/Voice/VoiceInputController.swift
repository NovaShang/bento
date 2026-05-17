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
    @Published var fingerScreenPosition: CGPoint = .zero

    private let audioCapture = AudioCaptureService()
    private var asrService: QwenASRService?
    private var holdOrigin: CGPoint = .zero
    private let directionThreshold: CGFloat = 40
    private var micAuthorized = false

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
        // Show overlay immediately for responsiveness.
        isRecording = true
        showOverlay = true
        transcript = ""
        activeDirection = .none

        if !micAuthorized {
            Task {
                let granted = await withCheckedContinuation { cont in
                    AVAudioApplication.requestRecordPermission { ok in
                        cont.resume(returning: ok)
                    }
                }
                if granted {
                    micAuthorized = true
                    beginRecording()
                } else {
                    dlog("Microphone permission denied")
                    transcript = "Microphone permission denied"
                    isRecording = false
                    try? await Task.sleep(for: .milliseconds(800))
                    showOverlay = false
                }
            }
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        HapticService.shared.prepare()
        HapticService.shared.recordingStarted()

        let apiKey = UserDefaults.standard.string(forKey: "qwen_api_key") ?? ""
        guard !apiKey.isEmpty else {
            transcript = "Set Qwen API key in Settings → Voice"
            isRecording = false
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                await MainActor.run { self.showOverlay = false }
            }
            return
        }

        let language = mapLocaleToQwen(UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
        let asr = QwenASRService(apiKey: apiKey, language: language)
        self.asrService = asr

        asr.onInterim = { [weak self] text in
            Task { @MainActor in self?.transcript = text }
        }
        asr.onFinal = { [weak self] text in
            Task { @MainActor in self?.transcript = text }
        }
        asr.onError = { [weak self] error in
            Task { @MainActor in
                dlog("ASR error: \(error.localizedDescription)")
                self?.transcript = error.localizedDescription
            }
        }

        audioCapture.onPCM = { [weak asr] pcm in
            Task { await asr?.sendAudio(pcm) }
        }

        Task {
            do {
                try await asr.start()
                try audioCapture.start()
            } catch {
                await MainActor.run {
                    dlog("Failed to start voice: \(error.localizedDescription)")
                    self.transcript = error.localizedDescription
                    self.isRecording = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        await MainActor.run { self.showOverlay = false }
                    }
                }
            }
        }
    }

    private func stopRecording(direction: VoiceDirection) {
        audioCapture.stop()
        let asr = asrService
        asrService = nil
        Task { await asr?.stop() }

        let finalText = transcript
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

    private func mapLocaleToQwen(_ locale: String) -> String {
        switch locale {
        case "zh-Hans", "zh-Hant", "zh": return "zh"
        case "en-US", "en-GB", "en": return "en"
        case "ja-JP", "ja": return "ja"
        default: return "auto"
        }
    }
}
