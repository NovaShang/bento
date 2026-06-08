import Foundation
import AVFoundation
import Speech

/// Cross-platform microphone + speech-recognition permission. iOS uses
/// `AVAudioApplication`; macOS uses `AVCaptureDevice` (and needs the
/// NSMicrophoneUsageDescription / NSSpeechRecognitionUsageDescription keys).
public enum MicPermission {
    /// Request (or confirm) microphone access.
    public static func ensureMic() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
        default: return false
        }
        #endif
    }

    /// Request (or confirm) speech-recognition access (needed for the Apple engine).
    public static func ensureSpeech() async -> Bool {
        await AppleSpeechEngine.requestAuthorization()
    }
}
