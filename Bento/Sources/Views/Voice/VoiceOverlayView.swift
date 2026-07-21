import SwiftUI
import BentoCore

/// iOS voice overlay — now a thin wrapper over the shared `VoiceCompassView`
/// (in BentoCore) so iOS and macOS render the exact same compass +
/// transcript bubble (one source of truth). Only hosting/positioning differs.
struct VoiceOverlayView: View {
    let transcript: String
    let activeDirection: VoiceDirection
    let isRecording: Bool

    var body: some View {
        VoiceCompassView(transcript: transcript, direction: activeDirection)
    }
}
