// Ported from frozen VoiceCompassView.swift + VoiceTypes.swift @ 8fa54b6^; data layer swapped, UI verbatim.
// The trunk's shared VoiceDirection dropped the left/right AI-shell arms in
// product A's voice redesign; the frozen terminal product keeps all four —
// so the frozen compass + its two types live on here, module-local.
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

import SwiftUI

/// The voice overlay's visual layer, shared by iOS + macOS: a glowing center dot
/// + dashed dead-zone ring, four direction arrows that light up on the active
/// direction, and a transcript bubble that windows the bottom 3 lines (newest
/// words pinned, older lines scroll off the top). Pure SwiftUI — no UIKit/AppKit
/// — so it renders identically wherever it's hosted (NSHostingView / iOS overlay).
public struct VoiceCompassView: View {
    public let transcript: String
    public let direction: VoiceDirection

    public init(transcript: String, direction: VoiceDirection) {
        self.transcript = transcript
        self.direction = direction
    }

    private let accent = Color(red: 0.30, green: 0.90, blue: 0.62)
    private let radius: CGFloat = 80

    public var body: some View {
        ZStack {
            compass
            bubble.offset(y: -(radius + 70))
        }
        // Fixed size so the compass center sits at the host's anchor point
        // (NSView frame on macOS, `.position` on iOS).
        .frame(width: 360, height: 380)
    }

    private var bubble: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("Listening").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
            }
            // Render the full text, then window the BOTTOM three lines
            // (bottom-aligned + clipped) so it scrolls up line-by-line like a log
            // tail; short text just sits at its natural height.
            Text(transcript.isEmpty ? "Listening…" : transcript)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(width: 248, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 60, alignment: .bottom)
                .clipped()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
    }

    private var compass: some View {
        ZStack {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(accent.opacity(0.4))
                .frame(width: 54, height: 54)
            Circle()
                .fill(accent)
                .frame(width: 16, height: 16)
                .shadow(color: accent.opacity(0.7), radius: 9)
            arrow(.up, "↑", "send", dx: 0, dy: -radius)
            arrow(.right, "→", "AI correct", dx: radius, dy: 0)
            arrow(.down, "↓", "cancel", dx: 0, dy: radius)
            arrow(.left, "←", "AI → shell", dx: -radius, dy: 0)
        }
    }

    private func arrow(_ d: VoiceDirection, _ icon: String, _ label: String,
                       dx: CGFloat, dy: CGFloat) -> some View {
        let hot = d == direction
        return VStack(spacing: 3) {
            Text(icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(hot ? .white : accent.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(Circle().fill(hot ? accent : Color.black.opacity(0.5)))
                .overlay(Circle().strokeBorder(hot ? accent : accent.opacity(0.4), lineWidth: 1.5))
                .shadow(color: hot ? accent.opacity(0.7) : .black.opacity(0.35), radius: hot ? 11 : 4)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hot ? accent : .white.opacity(0.6))
                .fixedSize()
        }
        .offset(x: dx, y: dy)
        .animation(.easeOut(duration: 0.12), value: hot)
    }
}

/// Compass direction from a press-origin translation (points, y-down). Shared by
/// both platforms so the dead-zone + axis logic is identical. (Module-local:
/// the trunk's twin answers the redesigned 3-direction vocabulary.)
public func voiceDirection(forTranslation t: CGSize, threshold: CGFloat = 40) -> VoiceDirection {
    let dx = t.width, dy = t.height
    if abs(dx) < threshold && abs(dy) < threshold { return .none }
    if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
    return dy < 0 ? .up : .down
}
