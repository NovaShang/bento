import UIKit
import SwiftUI
import AVFoundation
import Speech
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

    // Cloud engine state.
    private let audioCapture = AudioCaptureService()
    private var openaiService: OpenAIRealtimeASRService?

    // On-device (Apple) engine state. Allocated lazily per recording.
    private var appleEngine: AppleSpeechEngine?

    /// Which engine is active for the current recording session.
    private var currentEngine: SpeechEngineKind = .apple

    private enum SpeechEngineKind: String {
        case apple, openai
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
        case .apple:  beginAppleRecording()
        case .openai: beginOpenAIRecording()
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

    // MARK: - OpenAI (gpt-realtime-whisper)

    private func beginOpenAIRecording() {
        let defaults = UserDefaults.standard
        let apiKey = (defaults.string(forKey: "openai_api_key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Default to the bundled relay proxy when the user hasn't supplied a
        // direct API key, so the online service works zero-config.
        let proxyURL: URL? = apiKey.isEmpty ? OpenAIRealtimeASRService.defaultProxyURL : nil

        let language = mapLocaleToOpenAI(defaults.string(forKey: "speech_locale") ?? "auto")
        let asr = OpenAIRealtimeASRService(
            apiKey: apiKey,
            proxyURL: proxyURL,
            language: language
        )
        self.openaiService = asr

        asr.onInterim = { [weak self] text in
            Task { @MainActor in self?.transcript = text }
        }
        asr.onFinal = { [weak self] text in
            Task { @MainActor in self?.transcript = text }
        }
        asr.onError = { [weak self] error in
            Task { @MainActor in
                dlog("OpenAI ASR error: \(error.localizedDescription)")
                self?.transcript = error.localizedDescription
            }
        }

        audioCapture.onPCM = { [weak asr] pcm in
            Task { await asr?.sendAudio(pcm) }
        }

        Task {
            do {
                try await asr.start()
                try audioCapture.start(targetSampleRate: OpenAIRealtimeASRService.requiredSampleRate)
            } catch {
                await MainActor.run {
                    Task { [weak self] in
                        await self?.showTransientError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func endOpenAIRecording() -> String {
        audioCapture.stop()
        let asr = openaiService
        openaiService = nil
        Task { await asr?.stop() }
        return transcript
    }

    // MARK: - Stop

    private func stopRecording(direction: VoiceDirection) {
        let finalText: String
        switch currentEngine {
        case .apple:  finalText = endAppleRecording()
        case .openai: finalText = endOpenAIRecording()
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

    /// OpenAI expects ISO-639-1 ("zh","en","ja") or empty string for auto.
    private func mapLocaleToOpenAI(_ locale: String) -> String {
        switch locale {
        case "zh-Hans", "zh-Hant", "zh": return "zh"
        case "en-US", "en-GB", "en": return "en"
        case "ja-JP", "ja": return "ja"
        default: return ""
        }
    }
}

// MARK: - Voice → TerminalViewModel

extension TerminalViewModel {
    /// Handle a voice input result — inject text into the active pane. Lives in
    /// the iOS app (not BentoTerminalCore) because it depends on
    /// VoiceInputController.VoiceInputResult and LLMService.
    func handleVoiceResult(_ result: VoiceInputController.VoiceInputResult) {
        switch result.direction {
        case .none:
            sendString(result.text)
        case .up:
            sendString(result.text)
            if let data = "\r".data(using: .utf8) { sendData(data) }
        case .left, .right:
            // LLM-assisted: convert NL to a shell command using recent context.
            Task {
                let context = recentPaneContext()
                let command = await LLMService.shared.convertToShellCommand(
                    transcript: result.text,
                    context: context
                )
                if !command.isEmpty {
                    sendString(command)
                    if result.direction == .right {
                        if let data = "\r".data(using: .utf8) { sendData(data) }
                    }
                }
            }
        case .down:
            break
        }
    }

    /// Recent terminal text used as LLM context.
    private func recentPaneContext() -> String {
        if let activePaneID {
            return stateDetection.recentText(for: activePaneID, lines: 30)
        }
        return ""
    }
}
