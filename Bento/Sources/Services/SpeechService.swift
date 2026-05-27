import Foundation
import Speech
import AVFoundation

/// Protocol for speech recognition engine (future: swap to Whisper/SpeechAnalyzer)
protocol SpeechEngine {
    func startRecording(onPartialResult: @escaping @Sendable (String) -> Void) async throws
    func stopRecording() -> String?
    var isRecording: Bool { get }
}

/// SFSpeechRecognizer-based implementation for real-time streaming transcription
final class AppleSpeechEngine: NSObject, SpeechEngine, @unchecked Sendable {
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var latestTranscript = ""
    private(set) var isRecording = false

    override init() {
        super.init()
        refreshRecognizer()
    }

    /// Recreate recognizer with the locale from Settings
    private func refreshRecognizer() {
        let key = UserDefaults.standard.string(forKey: "speech_locale") ?? "auto"
        let locale: Locale = (key == "auto") ? .current : Locale(identifier: key)
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Request speech recognition authorization
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func startRecording(onPartialResult: @escaping @Sendable (String) -> Void) async throws {
        refreshRecognizer()
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechError.notAvailable
        }

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request

        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let transcript = result.bestTranscription.formattedString
                self?.latestTranscript = transcript
                onPartialResult(transcript)
            }
            if error != nil || (result?.isFinal ?? false) {
                self?.cleanupAudio()
            }
        }

        // Install audio tap
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }

    func stopRecording() -> String? {
        guard isRecording else { return nil }
        cleanupAudio()
        let result = latestTranscript
        latestTranscript = ""
        return result.isEmpty ? nil : result
    }

    private func cleanupAudio() {
        isRecording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}

enum SpeechError: LocalizedError {
    case notAvailable
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "Speech recognition is not available."
        case .notAuthorized: return "Speech recognition is not authorized."
        }
    }
}
