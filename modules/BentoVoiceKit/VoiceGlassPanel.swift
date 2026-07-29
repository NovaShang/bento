import BentoFoundation
import BentoUI
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
// Liquid Glass on OS 26+, falling back to thin material. All ink is adaptive
// (.primary/.secondary) so both appearances read; the active zone inflates +
// tints (send = green, discard = red) so you can see where release will land
// BEFORE letting go.

public struct VoiceGlassPanelView: View {
    public enum Variant: Sendable {
        /// Preview / send / insert / discard — the anywhere-hold panel,
        /// column centered (the panel is centered on the press point).
        case full
        /// Preview / send / insert — the composer-mic hold panel (no discard),
        /// column leading-aligned (it grows up from the bottom-left mic).
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

    public var body: some View {
        let leading = variant == .composer
        VStack(alignment: leading ? .leading : .center, spacing: 0) {
            VoiceTranscriptBubble(transcript: transcript)
                .frame(height: Self.bubbleHeight)
            Spacer().frame(height: Self.bubbleGap)
            zone(.up, icon: "arrow.up", title: "Send", caption: "slide up", tint: .green)
            Spacer().frame(height: Self.zoneGap)
            zone(.none, icon: "text.insert", title: "Insert", caption: "release here", tint: .accentColor)
            if variant == .full {
                Spacer().frame(height: Self.zoneGap)
                zone(.down, icon: "xmark", title: "Discard", caption: "slide down", tint: .red)
            }
        }
        .frame(width: Self.panelWidth, alignment: leading ? .leading : .center)
    }

    /// One drop zone: a glass capsule that inflates + tints while the drag
    /// points at it. The caption is the first-run teacher ("slide up" /
    /// "release here" / "slide down") — tiny, secondary, always there.
    private func zone(_ d: VoiceDirection, icon: String, title: String,
                      caption: String, tint: Color) -> some View {
        let hot = d == direction
        // On a saturated tint, white ink reads best; idle zones use adaptive
        // ink so light mode isn't white-on-white.
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(hot ? Color.white : tint)
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(hot ? Color.white : .primary)
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(hot ? Color.white.opacity(0.75) : .secondary)
        }
        .frame(width: Self.zoneWidth, height: Self.zoneHeight)
        .modifier(VoiceGlassChrome(shape: .capsule, tint: hot ? tint : nil))
        .shadow(color: hot ? tint.opacity(0.5) : .black.opacity(0.18),
                radius: hot ? 12 : 5, y: 3)
        .scaleEffect(hot ? 1.07 : 1.0, anchor: variant == .composer ? .leading : .center)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hot)
    }
}

/// The shared glass chrome for every voice element (zones + the transcript
/// bubble): Liquid Glass on OS 26+, thin material before, with one adaptive
/// hairline so the pieces read as one family. `tint` = the active zone's
/// color wash; nil = plain glass.
struct VoiceGlassChrome: ViewModifier {
    enum Shape { case capsule, roundedRect }
    var shape: Shape
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        let stroked = strokeShape()
        if #available(iOS 26.0, macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0.opacity(0.9)).interactive() }
                ?? Glass.regular.interactive()
            switch shape {
            case .capsule:     content.glassEffect(glass, in: .capsule).overlay(stroked)
            case .roundedRect: content.glassEffect(glass, in: .rect(cornerRadius: 16)).overlay(stroked)
            }
        } else {
            content
                .background {
                    if let tint {
                        anyShape().fill(tint.opacity(0.9))
                    } else {
                        anyShape().fill(.ultraThinMaterial)
                    }
                }
                .overlay(stroked)
        }
    }

    private func anyShape() -> AnyShape {
        switch shape {
        case .capsule:     return AnyShape(Capsule())
        case .roundedRect: return AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private func strokeShape() -> some View {
        let color = tint.map { $0.opacity(0.9) } ?? Color.primary.opacity(0.14)
        let width: CGFloat = tint == nil ? 1 : 1.5
        switch shape {
        case .capsule:
            Capsule().strokeBorder(color, lineWidth: width)
        case .roundedRect:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(color, lineWidth: width)
        }
    }
}
