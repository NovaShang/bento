import Foundation

/// Shared voice-recording driver: engine selection (Apple on-device / OpenAI
/// realtime), permission gating, audio capture, and start/stop. The platform
/// controllers (iOS `VoiceInputController`, macOS `MacVoiceController`) wrap this
/// and add the gesture, the compass direction, haptics, and the overlay — so the
/// gnarly engine code lives in exactly one place.
@MainActor
public final class VoiceSession {
    private let audioCapture = AudioCaptureService()
    private var openai: OpenAIRealtimeASRService?
    private var apple: AppleSpeechEngine?
    private var engine: SpeechEngineKind = .apple

    /// The most recent transcript seen (so `stop()` can return the final text
    /// even for the OpenAI engine, whose final arrives via a callback).
    private var lastTranscript = ""
    public private(set) var isActive = false

    /// PCM captured before the OpenAI socket is open, flushed once it connects so
    /// the opening words aren't lost to the (cold) WSS handshake latency.
    private var pendingPCM: [Data] = []
    private var openaiReady = false

    public init() {}

    /// Begin recording after ensuring permissions. `onPartial` streams the live
    /// transcript on the main actor; `onError` reports a user-facing message.
    public func start(onPartial: @escaping @MainActor (String) -> Void,
                      onError: @escaping @MainActor (String) -> Void) {
        // Defensive: never overlap sessions. If a prior recording is still active
        // (e.g. a failed one a caller didn't stop), tear it down first so we don't
        // leave a second mic engine / ASR socket running.
        if isActive { _ = stop() }
        engine = .current()
        isActive = true
        lastTranscript = ""
        dlog("[voice] start engine=\(engine)")
        Task {
            guard await MicPermission.ensureMic() else {
                dlog("[voice] mic permission DENIED")
                isActive = false; onError("Microphone permission denied"); return
            }
            if engine == .apple, await MicPermission.ensureSpeech() == false {
                dlog("[voice] speech permission DENIED")
                isActive = false; onError("Speech recognition permission denied"); return
            }
            dlog("[voice] permissions ok → begin \(engine)")
            switch engine {
            case .apple:  beginApple(onPartial: onPartial, onError: onError)
            case .openai: beginOpenAI(onPartial: onPartial, onError: onError)
            }
        }
    }

    /// Stop recording and return the final transcript (may be empty).
    public func stop() -> String {
        let final: String
        switch engine {
        case .apple:
            final = apple?.stopRecording() ?? lastTranscript
            apple = nil
        case .openai:
            audioCapture.stop()
            let asr = openai
            openai = nil
            openaiReady = false
            pendingPCM = []
            Task { await asr?.stop() }
            final = lastTranscript
        }
        isActive = false
        return final.isEmpty ? lastTranscript : final
    }

    // MARK: - Apple (on-device)

    private func beginApple(onPartial: @escaping @MainActor (String) -> Void,
                            onError: @escaping @MainActor (String) -> Void) {
        let eng = AppleSpeechEngine()
        apple = eng
        Task {
            do {
                try await eng.startRecording { partial in
                    Task { @MainActor in self.lastTranscript = partial; onPartial(partial) }
                }
                dlog("[voice] apple startRecording returned ok")
            } catch {
                dlog("[voice] apple startRecording FAILED: \(error.localizedDescription)")
                await MainActor.run { onError(error.localizedDescription) }
            }
        }
    }

    // MARK: - OpenAI (gpt-realtime-whisper)

    private func beginOpenAI(onPartial: @escaping @MainActor (String) -> Void,
                             onError: @escaping @MainActor (String) -> Void) {
        let defaults = UserDefaults.standard
        let apiKey = (defaults.string(forKey: "openai_api_key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyURL: URL? = apiKey.isEmpty ? OpenAIRealtimeASRService.defaultProxyURL : nil
        let language = openAILanguageHint(for: defaults.string(forKey: "speech_locale") ?? "auto")

        let asr = OpenAIRealtimeASRService(apiKey: apiKey, proxyURL: proxyURL, language: language)
        openai = asr
        pendingPCM = []
        openaiReady = false
        dlog("[voice] openai begin: byok=\(!apiKey.isEmpty) proxy=\(proxyURL != nil) lang=\(language ?? "auto")")
        asr.onInterim = { text in Task { @MainActor in self.lastTranscript = text; onPartial(text) } }
        asr.onFinal = { text in Task { @MainActor in self.lastTranscript = text; onPartial(text) } }
        asr.onError = { err in
            dlog("[voice] openai asr error: \(err.localizedDescription)")
            Task { @MainActor in onError(err.localizedDescription) }
        }
        // Buffer audio captured before the socket is open; flush on connect.
        audioCapture.onPCM = { [weak self, weak asr] pcm in
            Task { @MainActor in
                guard let self else { return }
                if self.openaiReady { await asr?.sendAudio(pcm) }
                else { self.pendingPCM.append(pcm) }
            }
        }

        // Start the mic immediately so the opening words are captured while the
        // (slower) WSS handshake runs.
        do {
            try audioCapture.start(targetSampleRate: OpenAIRealtimeASRService.requiredSampleRate)
            dlog("[voice] mic capture started")
        } catch {
            dlog("[voice] mic capture FAILED: \(error.localizedDescription)")
            onError(error.localizedDescription)
        }
        Task {
            do {
                try await asr.start()
                openaiReady = true
                let buffered = pendingPCM
                pendingPCM = []
                dlog("[voice] openai WSS connected; flushing \(buffered.count) buffered chunks")
                for pcm in buffered { await asr.sendAudio(pcm) }
            } catch {
                dlog("[voice] openai WSS start FAILED: \(error.localizedDescription)")
                await MainActor.run { onError(error.localizedDescription) }
            }
        }
    }
}

/// Compass direction from a press-origin translation (points, y-down). Shared by
/// both platforms so the dead-zone + axis logic is identical.
public func voiceDirection(forTranslation t: CGSize, threshold: CGFloat = 40) -> VoiceDirection {
    let dx = t.width, dy = t.height
    if abs(dx) < threshold && abs(dy) < threshold { return .none }
    if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
    return dy < 0 ? .up : .down
}
