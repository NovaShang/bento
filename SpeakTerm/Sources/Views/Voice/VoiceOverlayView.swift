import SwiftUI

/// Direction the user's finger moved from the hold origin
enum VoiceDirection: String {
    case none     // No significant movement — inject text only
    case up       // Inject text + newline (send command)
    case down     // Cancel
    case left     // LLM: convert to shell command
    case right    // LLM: convert to shell command
}

/// Compass-style voice recording overlay matching the design prototype.
/// Shows finger dot, 4 directional arrows, and transcript bubble above.
struct VoiceOverlayView: View {
    let transcript: String
    let activeDirection: VoiceDirection
    let isRecording: Bool

    private let compassRadius: CGFloat = 72
    private let arrowSize: CGFloat = 34
    private let accentBlue = Color.stAccent

    var body: some View {
        VStack(spacing: 0) {
            // Transcript bubble
            transcriptBubble
                .padding(.bottom, 20)

            // Compass
            compassView
                .frame(width: compassRadius * 2 + arrowSize, height: compassRadius * 2 + arrowSize)

            // Center hint
            Text("Release in center · insert only")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 16)
        }
    }

    // MARK: - Transcript Bubble

    private var transcriptBubble: some View {
        VStack(spacing: 5) {
            // Listening indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .opacity(isRecording ? 1 : 0)
                Text("Listening")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentBlue)
            }

            // Transcript text
            Text(transcript.isEmpty ? "Listening..." : transcript)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 240, maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        )
        .overlay(alignment: .bottom) {
            // Tail pointing down toward compass
            Triangle()
                .fill(.ultraThinMaterial)
                .frame(width: 12, height: 7)
                .offset(y: 7)
        }
    }

    // MARK: - Compass

    private var compassView: some View {
        ZStack {
            // Dead-zone ring (dashed)
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(accentBlue.opacity(0.45))
                .frame(width: 56, height: 56)

            // Finger dot
            Circle()
                .fill(accentBlue.opacity(0.95))
                .frame(width: 20, height: 20)
                .shadow(color: accentBlue.opacity(0.45), radius: 9)
                .shadow(color: accentBlue.opacity(0.2), radius: 3)

            // 4 directional arrows
            arrowButton(direction: .up, dx: 0, dy: -compassRadius, icon: "↑", label: "send")
            arrowButton(direction: .right, dx: compassRadius, dy: 0, icon: "→", label: "AI → shell")
            arrowButton(direction: .down, dx: 0, dy: compassRadius, icon: "↓", label: "cancel")
            arrowButton(direction: .left, dx: -compassRadius, dy: 0, icon: "←", label: "AI → shell")
        }
    }

    private func arrowButton(direction: VoiceDirection, dx: CGFloat, dy: CGFloat, icon: String, label: String) -> some View {
        let isHot = activeDirection == direction

        return VStack(spacing: 4) {
            // Arrow circle
            Text(icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(isHot ? .white : Color(hex: 0x7FB6FF))
                .frame(width: arrowSize, height: arrowSize)
                .background(
                    Circle()
                        .fill(isHot ? accentBlue : Color(hex: 0x14161C, opacity: 0.88))
                        .overlay(
                            Circle()
                                .strokeBorder(isHot ? accentBlue : accentBlue.opacity(0.45), lineWidth: 1.5)
                        )
                )
                .shadow(color: isHot ? accentBlue.opacity(0.7) : .black.opacity(0.4),
                        radius: isHot ? 12 : 6)

            // Label
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(isHot ? accentBlue : .white.opacity(0.72))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(hex: 0x0B0C10, opacity: 0.72))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .offset(x: dx, y: dy)
        .animation(.easeInOut(duration: 0.14), value: isHot)
    }
}

// MARK: - Helpers

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
