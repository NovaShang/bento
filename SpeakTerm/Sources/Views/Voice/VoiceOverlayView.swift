import SwiftUI

/// Direction the user's finger moved from the hold origin
enum VoiceDirection: String {
    case none     // No significant movement — inject text only
    case up       // Inject text + newline (send command)
    case down     // Cancel
    case left     // LLM: convert to shell command
    case right    // LLM: convert to shell command
}

/// The floating voice recording overlay shown on the held pane.
/// Displays real-time transcript and directional hints.
struct VoiceOverlayView: View {
    let transcript: String
    let activeDirection: VoiceDirection
    let isRecording: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Direction hint: UP
            directionLabel("Send", direction: .up, icon: "arrow.up")

            HStack(spacing: 24) {
                // Direction hint: LEFT
                directionLabel("Shell", direction: .left, icon: "arrow.left")

                // Center: transcript
                VStack(spacing: 8) {
                    if isRecording {
                        recordingIndicator
                    }
                    Text(transcript.isEmpty ? "Listening..." : transcript)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .frame(maxWidth: 200)
                }

                // Direction hint: RIGHT
                directionLabel("Shell", direction: .right, icon: "arrow.right")
            }

            // Direction hint: DOWN
            directionLabel("Cancel", direction: .down, icon: "arrow.down")
        }
        .padding(20)
        .background(.ultraThinMaterial.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 20)
    }

    private func directionLabel(_ text: String, direction: VoiceDirection, icon: String) -> some View {
        let isActive = activeDirection == direction
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(isActive ? .white : .white.opacity(0.4))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? Color.blue : Color.clear)
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    private var recordingIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Recording")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}
