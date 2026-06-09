#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI

/// macOS hold-to-talk voice controller. Wraps the shared `VoiceSession` (engine
/// + permissions + audio) and adds the compass direction + published state the
/// overlay binds to. One per terminal window, owned by `GhosttyTiledPaneHost`.
@MainActor
public final class MacVoiceController: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var transcript = ""
    @Published public private(set) var activeDirection: VoiceDirection = .none

    private let session = VoiceSession()
    private var originScreen: CGPoint = .zero
    private var errorClear: DispatchWorkItem?

    /// Fired with the final utterance + direction (unless cancelled/empty).
    public var onResult: ((VoiceInputResult) -> Void)?

    public init() {}

    /// Begin hold-to-talk, anchored at a screen point (for direction tracking).
    public func begin(originScreen: CGPoint) {
        guard !isRecording else { return }
        errorClear?.cancel()
        self.originScreen = originScreen
        isRecording = true
        transcript = ""
        activeDirection = .none
        session.start(
            onPartial: { [weak self] t in self?.transcript = t },
            onError: { [weak self] msg in self?.fail(msg) })
    }

    /// Update the compass from the current cursor location (screen points).
    public func update(toScreen p: CGPoint) {
        guard isRecording else { return }
        // macOS screen coords are y-up; flip dy so an upward drag reads as `.up`.
        let t = CGSize(width: p.x - originScreen.x, height: -(p.y - originScreen.y))
        activeDirection = voiceDirection(forTranslation: t)
    }

    /// End hold-to-talk; routes the result unless cancelled (↓) or empty.
    public func end() {
        guard isRecording else { return }
        let dir = activeDirection
        let text = session.stop()
        isRecording = false
        activeDirection = .none
        guard dir != .down, !text.isEmpty else { return }
        onResult?(VoiceInputResult(text: text, direction: dir))
    }

    private func fail(_ message: String) {
        // Release the mic engine + ASR NOW. Without this a failed/dropped session
        // (e.g. "network connection was lost") leaves the AVAudioEngine running;
        // the next recording then installs a SECOND tap on the same input bus,
        // corrupting CoreAudio and hanging the main thread — the terminal froze
        // after a "network lost" voice error.
        _ = session.stop()
        transcript = message
        // Leave the overlay up briefly so the error is readable, then dismiss.
        let work = DispatchWorkItem { [weak self] in self?.isRecording = false }
        errorClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

/// Compass + transcript overlay, rendered in SwiftUI (materials, shadows, smooth
/// highlight) and hosted in AppKit. The host sizes/positions and shows/hides it;
/// it never intercepts the mouse (the recording drag belongs to the surface).
@MainActor
public final class MacVoiceOverlay: NSView {
    public static let preferredSize = NSSize(width: 360, height: 380)

    private let hosting: NSHostingView<VoiceCompassView>

    public override init(frame frameRect: NSRect) {
        hosting = NSHostingView(rootView: VoiceCompassView(transcript: "", direction: .none))
        super.init(frame: frameRect)
        wantsLayer = true
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public var transcript: String = "" { didSet { rebuild() } }
    public var direction: VoiceDirection = .none { didSet { rebuild() } }

    private func rebuild() {
        hosting.rootView = VoiceCompassView(transcript: transcript, direction: direction)
    }
}

#endif
