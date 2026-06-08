import Foundation

// Shared voice-input types, lifted out of the iOS app so macOS + iOS use one
// engine. The gesture/overlay/haptics stay per-platform; everything here is
// platform-neutral. See docs/prd.md §3.2 (voice = the product's core gesture).

/// Direction the user moved from the press origin while dictating — the
/// "compass" that decides what happens to the transcript.
public enum VoiceDirection: String, Sendable {
    case none     // No significant movement — insert text only
    case up       // Insert text + newline (send command)
    case down     // Cancel
    case left     // LLM: convert to shell command
    case right    // LLM: convert to shell command + send
}

/// A finished voice utterance + the direction modifier chosen on release.
public struct VoiceInputResult: Sendable {
    public let text: String
    public let direction: VoiceDirection
    public init(text: String, direction: VoiceDirection) {
        self.text = text
        self.direction = direction
    }
}

/// Which ASR engine a recording uses, from the `speech_engine` user setting.
public enum SpeechEngineKind: String, Sendable {
    case apple, openai
    public static func current() -> SpeechEngineKind {
        let raw = UserDefaults.standard.string(forKey: "speech_engine") ?? "apple"
        return SpeechEngineKind(rawValue: raw) ?? .apple
    }
}

/// Protocol for a streaming speech-recognition engine.
public protocol SpeechEngine: AnyObject {
    func startRecording(onPartialResult: @escaping @Sendable (String) -> Void) async throws
    func stopRecording() -> String?
    var isRecording: Bool { get }
}

public enum SpeechError: LocalizedError {
    case notAvailable
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .notAvailable: return "Speech recognition is not available."
        case .notAuthorized: return "Speech recognition is not authorized."
        }
    }
}

/// Map a `speech_locale` setting to OpenAI's ISO-639-1 hint ("" = auto).
public func openAILanguageHint(for locale: String) -> String {
    switch locale {
    case "zh-Hans", "zh-Hant", "zh": return "zh"
    case "en-US", "en-GB", "en": return "en"
    case "ja-JP", "ja": return "ja"
    default: return ""
    }
}
