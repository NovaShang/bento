import BentoFoundation
import BentoUI
import SwiftUI

// The old 4-arrow VoiceCompassView (send / AI-correct / cancel / AI→shell)
// lived here — a terminal-era artifact, replaced by VoiceGlassPanelView (see
// VoiceGlassPanel.swift). What remains is the one piece every voice surface
// still shares: the floating live-transcript bubble.

/// The floating "Listening" transcript box — a glass bubble that windows the
/// bottom three lines of the live transcript (newest words pinned, older lines
/// scroll off the top). The preview layer of the hold-to-talk glass panel, and
/// floated solo above the composer for the mic-button quick dictation — so
/// every voice entry shows the exact same preview.
public struct VoiceTranscriptBubble: View {
    public let transcript: String
    public init(transcript: String) { self.transcript = transcript }

    public var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("Listening").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
            }
            // Render the full text, then window the BOTTOM three lines
            // (bottom-aligned + clipped) so it scrolls up line-by-line like a log
            // tail; short text just sits at its natural height.
            Text(transcript.isEmpty ? "Listening…" : transcript)
                .font(.system(size: 14))
                .foregroundStyle(transcript.isEmpty ? Color.secondary : .primary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(width: 248, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
                // Fixed three-line-tall window (bottom-aligned): short text keeps
                // the box from collapsing; long text scrolls up to the newest 3.
                .frame(height: 64, alignment: .bottom)
                .clipped()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 280)
        // Same chrome family as the glass zones (VoiceGlassChrome), so the
        // bubble and the zone capsules read as one panel — and the ink is
        // adaptive, not the old white-on-anything.
        .modifier(VoiceGlassChrome(shape: .roundedRect))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}
