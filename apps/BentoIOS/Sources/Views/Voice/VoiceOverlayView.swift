#if canImport(UIKit)
import SwiftUI
import BentoFoundation
import BentoUI
import BentoWorkbench
import BentoVoiceKit
import BentoFilePreviewKit
import BentoLink

/// iOS voice overlay — a thin wrapper over the shared `VoiceGlassPanelView`
/// (in BentoCore) so iOS and macOS render the exact same glass zone panel +
/// transcript bubble (one source of truth). Only hosting/positioning differs:
/// the host `.position`s this view's CENTER, so expose the offset that puts
/// the INPUT zone (not the center) under the finger.
struct VoiceOverlayView: View {
    let transcript: String
    let activeDirection: VoiceDirection
    let isRecording: Bool

    /// Add to the press point's y to get the `.position` center-y that lands
    /// the input zone's center on the press point (SwiftUI y-down).
    static var centerOffsetFromPress: CGFloat {
        VoiceGlassPanelView.panelSize(variant: .full).height / 2
            - VoiceGlassPanelView.inputZoneCenterFromTop
    }

    var body: some View {
        VoiceGlassPanelView(
            transcript: transcript, direction: activeDirection, variant: .full)
    }
}

#endif
