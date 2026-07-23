import SwiftUI

// The hold-to-talk zone panel — the ACP-era replacement for the old 4-arrow
// terminal compass. A vertical stack of "drop zones" under the finger/cursor:
//
//   ┌ preview bubble ┐   (top — never covered by the finger)
//   │    ↑ Send      │   slide up
//   │    ● Insert    │   the press origin; release here = into the composer
//   │    ↓ Discard   │   slide down (full variant only)
//
// Shared by every entry point so the language is ONE: the pane hold gesture
// (two-finger on iOS, right-click on macOS — a trackpad two-finger press IS a
// right-click, so the platforms meet) shows the full panel; the composer mic's
// long-press shows the composer variant (no discard — the button sits on the
// bottom edge, there's no "down" to give it).
//
// Liquid Glass on OS 26+, falling back to thin material. The active zone
// inflates + tints (send = the voice accent green, discard = red) so you can
// see where release will land BEFORE letting go.

public struct VoiceGlassPanelView: View {
    public enum Variant: Sendable {
        /// Preview / send / insert / discard — the anywhere-hold panel.
        case full
        /// Preview / send / insert — the composer-mic hold panel (no discard).
        case composer
    }

    public let transcript: String
    public let direction: VoiceDirection
    public let variant: Variant

    public init(transcript: String, direction: VoiceDirection, variant: Variant) {
        self.transcript = transcript
        self.direction = direction
        self.variant = variant
    }

    // MARK: Geometry (statics so hosts can anchor the INPUT zone at the press point)

    /// Fixed height the preview bubble is framed to inside the panel (its
    /// intrinsic ~3-line size), so the anchor math below is deterministic.
    private static let bubbleHeight: CGFloat = 110
    private static let zoneHeight: CGFloat = 46
    private static let zoneWidth: CGFloat = 232
    private static let bubbleGap: CGFloat = 12
    private static let zoneGap: CGFloat = 8

    public static let panelWidth: CGFloat = 300

    public static func panelSize(variant: Variant) -> CGSize {
        let zones: CGFloat = variant == .full ? 3 : 2
        let gaps = bubbleGap + (zones - 1) * zoneGap
        return CGSize(width: panelWidth,
                      height: bubbleHeight + gaps + zones * zoneHeight)
    }

    /// Distance from the panel's TOP edge to the input zone's center — hosts
    /// place this point at the press origin so the finger starts ON the input
    /// zone (release-with-no-drag = the safe default). Same for both variants
    /// (the input zone is always bubble → send → input from the top).
    public static let inputZoneCenterFromTop: CGFloat =
        bubbleHeight + bubbleGap + zoneHeight + zoneGap + zoneHeight / 2

    private let accent = Color(red: 0.30, green: 0.90, blue: 0.62)

    public var body: some View {
        VStack(spacing: 0) {
            VoiceTranscriptBubble(transcript: transcript)
                .frame(height: Self.bubbleHeight)
            Spacer().frame(height: Self.bubbleGap)
            zone(.up, icon: "arrow.up", title: "Send", caption: "slide up", tint: accent)
            Spacer().frame(height: Self.zoneGap)
            zone(.none, icon: "text.insert", title: "Insert", caption: "release here", tint: .white)
            if variant == .full {
                Spacer().frame(height: Self.zoneGap)
                zone(.down, icon: "xmark", title: "Discard", caption: "slide down", tint: .red)
            }
        }
        .frame(width: Self.panelWidth)
    }

    /// One drop zone: a glass capsule that inflates + tints while the drag
    /// points at it. The caption is the first-run teacher ("slide up" /
    /// "release here" / "slide down") — tiny, tertiary, always there.
    private func zone(_ d: VoiceDirection, icon: String, title: String,
                      caption: String, tint: Color) -> some View {
        let hot = d == direction
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(hot ? Color.black.opacity(0.8) : tint.opacity(0.9))
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(hot ? Color.black.opacity(0.85) : .white)
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(hot ? Color.black.opacity(0.55) : .white.opacity(0.45))
        }
        .frame(width: Self.zoneWidth, height: Self.zoneHeight)
        .modifier(VoiceGlassChrome(tint: hot ? tint : nil))
        .overlay(Capsule().strokeBorder(
            hot ? tint : Color.white.opacity(0.14), lineWidth: hot ? 1.5 : 1))
        .shadow(color: hot ? tint.opacity(0.55) : .black.opacity(0.25),
                radius: hot ? 14 : 6, y: 3)
        .scaleEffect(hot ? 1.07 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hot)
    }
}

/// Liquid Glass capsule chrome on OS 26+, thin-material capsule before that.
/// `tint` = the active zone's color wash; nil = plain glass.
private struct VoiceGlassChrome: ViewModifier {
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0.opacity(0.85)).interactive() }
                ?? Glass.regular.interactive()
            content.glassEffect(glass, in: .capsule)
        } else {
            content.background {
                if let tint {
                    Capsule().fill(tint.opacity(0.85))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
        }
    }
}
