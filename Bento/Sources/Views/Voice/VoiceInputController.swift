import UIKit
import SwiftUI
import AVFoundation
import Speech

/// Manages the voice input gesture + recording lifecycle.
/// Added to a pane's terminal view as a long-press gesture recognizer.
///
/// Flow: hold >200ms → start recording → move finger → direction detection →
///       release → inject text based on direction
///
/// Two speech engines are supported and chosen per-recording from the
/// `speech_engine` user setting:
/// - "apple": on-device `SFSpeechRecognizer` (no API key, may have lower
///   accuracy / language coverage; requires speech-recognition permission).
/// - "qwen":  cloud DashScope Qwen-ASR-Realtime over WebSocket (requires
///   API key in `qwen_api_key`).
@MainActor
final class VoiceInputController: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var activeDirection: VoiceDirection = .none
    @Published var showOverlay = false
    @Published var fingerScreenPosition: CGPoint = .zero

    // Cloud (Qwen) engine state
    private let audioCapture = AudioCaptureService()
    private var asrService: QwenASRService?

    // On-device (Apple) engine state. Allocated lazily per recording.
    private var appleEngine: AppleSpeechEngine?

    /// Which engine is active for the current recording session.
    private var currentEngine: SpeechEngineKind = .apple

    private enum SpeechEngineKind: String {
        case apple, qwen
        static func current() -> SpeechEngineKind {
            let raw = UserDefaults.standard.string(forKey: "speech_engine") ?? "apple"
            return SpeechEngineKind(rawValue: raw) ?? .apple
        }
    }

    private var holdOrigin: CGPoint = .zero
    private let directionThreshold: CGFloat = 40
    private var micAuthorized = false
    private var speechAuthorized = false

    /// Called when voice input produces a result
    var onResult: ((VoiceInputResult) -> Void)?

    struct VoiceInputResult {
        let text: String
        let direction: VoiceDirection
    }

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
            holdOrigin = location
            fingerScreenPosition = location
            startRecording()

        case .changed:
            fingerScreenPosition = location
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
        currentEngine = SpeechEngineKind.current()

        Task {
            let micOK = await ensureMicPermission()
            guard micOK else {
                await showTransientError("Microphone permission denied")
                return
            }
            if currentEngine == .apple {
                let speechOK = await ensureSpeechPermission()
                guard speechOK else {
                    await showTransientError("Speech recognition permission denied")
                    return
                }
            }
            beginRecording()
        }
    }

    private func ensureMicPermission() async -> Bool {
        if micAuthorized { return true }
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        micAuthorized = granted
        return granted
    }

    private func ensureSpeechPermission() async -> Bool {
        if speechAuthorized { return true }
        let granted = await AppleSpeechEngine.requestAuthorization()
        speechAuthorized = granted
        return granted
    }

    private func showTransientError(_ message: String) async {
        dlog(message)
        transcript = message
        isRecording = false
        try? await Task.sleep(for: .milliseconds(1200))
        showOverlay = false
    }

    private func beginRecording() {
        HapticService.shared.prepare()
        HapticService.shared.recordingStarted()
        switch currentEngine {
        case .apple: beginAppleRecording()
        case .qwen:  beginQwenRecording()
        }
    }

    // MARK: - Apple (on-device)

    private func beginAppleRecording() {
        let engine = AppleSpeechEngine()
        self.appleEngine = engine
        Task {
            do {
                try await engine.startRecording { [weak self] partial in
                    Task { @MainActor in self?.transcript = partial }
                }
            } catch {
                await MainActor.run { [weak self] in
                    Task { await self?.showTransientError(error.localizedDescription) }
                }
            }
        }
    }

    private func endAppleRecording() -> String {
        let final = appleEngine?.stopRecording() ?? transcript
        appleEngine = nil
        return final.isEmpty ? transcript : final
    }

    // MARK: - Qwen (cloud)

    private func beginQwenRecording() {
        let apiKey = UserDefaults.standard.string(forKey: "qwen_api_key") ?? ""
        guard !apiKey.isEmpty else {
            Task { await showTransientError("Set Qwen API key in Settings → Speech") }
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
                    Task { [weak self] in
                        await self?.showTransientError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func endQwenRecording() -> String {
        audioCapture.stop()
        let asr = asrService
        asrService = nil
        Task { await asr?.stop() }
        return transcript
    }

    // MARK: - Stop

    private func stopRecording(direction: VoiceDirection) {
        let finalText: String
        switch currentEngine {
        case .apple: finalText = endAppleRecording()
        case .qwen:  finalText = endQwenRecording()
        }
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
