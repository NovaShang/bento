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

    /// The most recent transcript seen (so `finish()` can return the final text
    /// even for the OpenAI engine, whose final arrives via a callback).
    private var lastTranscript = ""
    public private(set) var isActive = false

    /// Wall-clock of the last streamed interim. Lets `finish()` tell "spoke, then
    /// released" (interim has settled → send it immediately) from "released mid-
    /// speech" (wait briefly for the tail). nil until the first interim arrives.
    private var lastInterimAt: Date?

    /// The transcript streamed so far this session — read by the right-swipe
    /// preview to seed its editor while the batch model re-transcribes.
    public var currentTranscript: String { lastTranscript }

    /// Set when the OpenAI realtime engine delivers a non-empty final / emits its
    /// `completed` event after a commit — so `finish()` stops waiting promptly.
    private var openaiFinalArrived = false
    private var openaiCompleted = false

    /// PCM captured before the OpenAI socket is open, flushed once it connects so
    /// the opening words aren't lost to the (cold) WSS handshake latency.
    private var pendingPCM: [Data] = []
    private var openaiReady = false

    /// The whole utterance's PCM, accumulated across the entire recording (OpenAI
    /// engine only — Apple's engine captures audio internally and never hits
    /// `audioCapture`). The right-swipe preview flow grabs this after `stop()` to
    /// re-transcribe the full clip with a higher-accuracy batch model.
    private var recordedPCM = Data()

    public init() {}

    /// Pre-allocate the mic engine ahead of an imminent recording (e.g. the right
    /// button just went down) so the actual `start()` reaches the mic in a few ms
    /// instead of paying the cold-start tax. Cheap, idempotent, no mic indicator.
    public func prewarm() {
        audioCapture.prewarm()
    }

    /// Begin recording after ensuring permissions. `onPartial` streams the live
    /// transcript on the main actor; `onError` reports a user-facing message.
    public func start(onPartial: @escaping @MainActor (String) -> Void,
                      onError: @escaping @MainActor (String) -> Void) {
        // Defensive: never overlap sessions. If a prior recording is still active
        // (e.g. a failed one a caller didn't stop), tear it down first so we don't
        // leave a second mic engine / ASR socket running.
        if isActive { cancel() }
        engine = .current()
        isActive = true
        lastTranscript = ""
        lastInterimAt = nil
        recordedPCM = Data()
        openaiFinalArrived = false
        openaiCompleted = false
        dlog("[voice] start engine=\(engine)")

        // Fast path: when permission is already granted (the common case after the
        // first grant), begin the engine INLINE on this main-actor turn — no Task
        // hop, no async permission round-trip — so the mic goes live immediately
        // instead of a few hundred ms after the compass appears.
        let needsSpeech = (engine == .apple)
        if MicPermission.micAuthorizedSync(), !needsSpeech || MicPermission.speechAuthorizedSync() {
            dlog("[voice] permission pre-granted → begin \(engine) inline")
            switch engine {
            case .apple:  beginApple(onPartial: onPartial, onError: onError)
            case .openai: beginOpenAI(onPartial: onPartial, onError: onError)
            }
            return
        }

        // Slow path: permission not yet determined — request it, then begin.
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

    /// Quiet the interim must have been at release to treat it as the complete
    /// utterance — i.e. the user finished speaking, *then* released. Below this the
    /// release looks mid-word, so we still wait briefly for the tail.
    private static let settleThresholdMs: Double = 300
    /// Bounded wait for the tail when released mid-speech (down from 800 — we only
    /// pay it in the uncommon mid-speech case now, not on every send).
    private static let tailGraceMs = 300

    /// Milliseconds since the last streamed interim (∞ if none arrived).
    private var quietMs: Double {
        guard let t = lastInterimAt else { return .infinity }
        return Date().timeIntervalSince(t) * 1000
    }
    /// The streamed transcript is non-empty and has stopped changing → it already
    /// holds the whole utterance, so there's nothing to wait for.
    private var interimSettled: Bool {
        !lastTranscript.isEmpty && quietMs >= Self.settleThresholdMs
    }

    /// Stop recording and resolve the BEST final transcript.
    ///
    /// Adaptive: if the streamed interim has already settled (the user spoke, then
    /// released), it IS the final — return it immediately, no round-trip, so the
    /// common case sends instantly. Only when the release looks mid-speech do we
    /// wait a short grace for the tail, falling back to a whole-clip batch
    /// transcription if streaming caught nothing. `language` is the batch hint.
    public func finish(language: String) async -> String {
        isActive = false
        let settled = interimSettled
        switch engine {
        case .apple:
            // Settled partial → return it now (non-awaiting stop); otherwise await
            // the on-device final (bounded internally) to catch the tail.
            if settled {
                let t = apple?.stopRecording() ?? lastTranscript
                apple = nil
                return t.isEmpty ? lastTranscript : t
            }
            let final = await apple?.finishRecording() ?? lastTranscript
            apple = nil
            return final.isEmpty ? lastTranscript : final

        case .openai:
            audioCapture.stop()
            let asr = openai
            // Fast path: interim already complete → send it, tidy the socket in the
            // background. No commit, no wait, no "识别中".
            if settled {
                let streamed = lastTranscript
                openai = nil
                openaiReady = false
                pendingPCM = []
                Task { await asr?.cancel() }
                return streamed
            }
            // Released mid-speech: commit the buffer and wait (briefly, bounded)
            // for the realtime final. The socket stays open during this so the
            // `completed` event is actually processed (updates lastTranscript).
            await asr?.commit()
            await waitForOpenAIFinal(graceMs: Self.tailGraceMs)
            let streamed = lastTranscript
            await asr?.cancel()
            openai = nil
            openaiReady = false
            pendingPCM = []
            if !streamed.isEmpty { return streamed }
            // Realtime delivered nothing (short clip): batch-transcribe the full
            // captured clip so the utterance is never lost.
            guard !recordedPCM.isEmpty else { return "" }
            dlog("[voice] realtime empty → batch fallback (\(recordedPCM.count) bytes)")
            let better = await BatchTranscriptionService.shared.transcribe(
                pcm: recordedPCM, sampleRate: OpenAIRealtimeASRService.requiredSampleRate, language: language)
            return better ?? ""
        }
    }

    /// Tear down immediately WITHOUT resolving a final transcript (cancel ↓ /
    /// error / right-swipe, which re-transcribes the clip itself / defensive
    /// re-entry). Preserves `recordedPCM` so a caller can still batch it.
    public func cancel() {
        switch engine {
        case .apple:
            _ = apple?.stopRecording()
            apple = nil
        case .openai:
            audioCapture.stop()
            let asr = openai
            openai = nil
            openaiReady = false
            pendingPCM = []
            Task { await asr?.cancel() }
        }
        isActive = false
    }

    /// Poll for the OpenAI realtime final after a commit, up to `graceMs`. Returns
    /// as soon as the `completed` event arrives (the flags are set on the main
    /// actor by the ASR callbacks, which run while this awaits).
    private func waitForOpenAIFinal(graceMs: Int) async {
        let ticks = max(1, graceMs / 20)
        for _ in 0..<ticks {
            if openaiFinalArrived || openaiCompleted { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The complete recorded audio of the just-finished session as 16-bit mono
    /// PCM + its sample rate, for the right-swipe batch re-transcription. Survives
    /// `stop()` (cleared on the next `start()`). Nil when no PCM was captured —
    /// e.g. the Apple on-device engine, which records internally.
    public func takeRecordedPCM() -> (pcm: Data, sampleRate: Double)? {
        guard !recordedPCM.isEmpty else { return nil }
        return (recordedPCM, OpenAIRealtimeASRService.requiredSampleRate)
    }

    // MARK: - Apple (on-device)

    private func beginApple(onPartial: @escaping @MainActor (String) -> Void,
                            onError: @escaping @MainActor (String) -> Void) {
        let eng = AppleSpeechEngine()
        apple = eng
        Task {
            do {
                try await eng.startRecording { partial in
                    Task { @MainActor in
                        self.lastTranscript = partial; self.lastInterimAt = Date(); onPartial(partial)
                    }
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
        asr.onInterim = { text in Task { @MainActor in
            self.lastTranscript = text; self.lastInterimAt = Date(); onPartial(text)
        } }
        asr.onFinal = { text in Task { @MainActor in
            self.lastTranscript = text; self.openaiFinalArrived = true; onPartial(text)
        } }
        asr.onCompleted = { Task { @MainActor in self.openaiCompleted = true } }
        asr.onError = { err in
            dlog("[voice] openai asr error: \(err.localizedDescription)")
            Task { @MainActor in onError(err.localizedDescription) }
        }
        // Buffer audio captured before the socket is open; flush on connect.
        audioCapture.onPCM = { [weak self, weak asr] pcm in
            Task { @MainActor in
                guard let self else { return }
                self.recordedPCM.append(pcm)   // full clip for the right-swipe batch path
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
