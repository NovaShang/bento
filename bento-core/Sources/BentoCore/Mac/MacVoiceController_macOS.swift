#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI

/// macOS hold-to-talk voice controller. Wraps the shared `VoiceSession` (engine
/// + permissions + audio) and adds the zone direction + published state the
/// glass-panel overlay binds to. One per window, owned by `TiledPaneHost`.
///
/// Release semantics (the shared glass-panel contract):
///   slide up = send · release at origin = insert into the composer · slide
///   down = discard. The old right-swipe "AI correct" preview and left-swipe
///   shell conversion are gone with the terminal.
@MainActor
public final class MacVoiceController: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var transcript = ""
    @Published public private(set) var activeDirection: VoiceDirection = .none

    private let session = VoiceSession()
    private var originScreen: CGPoint = .zero
    private var errorClear: DispatchWorkItem?

    /// Fired with the final utterance + direction (unless discarded/empty).
    public var onResult: ((VoiceInputResult) -> Void)?

    /// Supplies the active pane's recent on-screen text for Qwen context biasing;
    /// set by the pane host (which owns the chat surface). Forwarded to the
    /// shared `VoiceSession` so the Qwen engine can bias toward on-screen entities.
    public var readScreenText: (() -> String?)?

    public init() {
        session.contextProvider = { [weak self] in self?.readScreenText?() }
    }

    /// Pre-allocate the mic engine the moment a voice gesture becomes likely (the
    /// right button goes down), so the recording that may follow starts instantly.
    public func prewarm() {
        session.prewarm()
    }

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

    /// Update the zone highlight from the current cursor location (screen points).
    public func update(toScreen p: CGPoint) {
        guard isRecording else { return }
        // macOS screen coords are y-up; flip dy so an upward drag reads as `.up`.
        let t = CGSize(width: p.x - originScreen.x, height: -(p.y - originScreen.y))
        activeDirection = voiceDirection(forTranslation: t)
    }

    /// End hold-to-talk; routes the result unless discarded (↓) or empty.
    /// `activeDirection` deliberately KEEPS the released zone through the
    /// finalize — resetting it here made the highlight snap Send → Insert
    /// before the panel disappeared. `begin()` re-arms it to .none.
    public func end() {
        guard isRecording else { return }
        let dir = activeDirection

        if dir == .down {
            session.cancel()
            isRecording = false
            // Reset AFTER the overlay hides (isRecording drives it), so the
            // hot→idle transition runs invisibly — resetting while visible
            // (or leaving it stale) leaks last release's highlight into the
            // next open as a spurious Send→Insert animation.
            activeDirection = .none
            return
        }
        // up (send) / none (insert) → resolve the reliable final. A settled
        // utterance resolves instantly; only a mid-speech release waits. Show
        // "识别中…" only if that wait actually drags on (>200ms).
        Task { [weak self] in
            guard let self else { return }
            let lang = openAILanguageHint(for: UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
            let indicator = DispatchWorkItem { [weak self] in self?.transcript = "识别中…" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: indicator)
            let text = await self.session.finish(language: lang)
            indicator.cancel()
            self.isRecording = false
            // Post-hide reset (see the .down branch note).
            self.activeDirection = .none
            guard !text.isEmpty else { return }
            TelemetryService.shared.record(.voiceSend)
            TelemetryService.shared.record(.voiceFirstSend)
            self.onResult?(VoiceInputResult(text: text, direction: dir))
        }
    }

    private func fail(_ message: String) {
        // Release the mic engine + ASR NOW. Without this a failed/dropped session
        // (e.g. "network connection was lost") leaves the AVAudioEngine running;
        // the next recording then installs a SECOND tap on the same input bus,
        // corrupting CoreAudio and hanging the main thread — the terminal froze
        // after a "network lost" voice error.
        session.cancel()
        transcript = message
        // Leave the overlay up briefly so the error is readable, then dismiss.
        let work = DispatchWorkItem { [weak self] in
            self?.isRecording = false
            self?.activeDirection = .none
        }
        errorClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

/// Glass zone panel + transcript overlay, rendered in SwiftUI and hosted in
/// AppKit. The host sizes/positions it so the INPUT zone sits at the press
/// point; it never intercepts the mouse (the recording drag belongs to the
/// surface).
@MainActor
public final class MacVoiceOverlay: NSView {
    public static let preferredSize = NSSize(
        width: VoiceGlassPanelView.panelSize(variant: .full).width,
        height: VoiceGlassPanelView.panelSize(variant: .full).height)

    private let hosting: NSHostingView<VoiceGlassPanelView>

    public override init(frame frameRect: NSRect) {
        hosting = NSHostingView(rootView: VoiceGlassPanelView(
            transcript: "", direction: .none, variant: .full))
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
        hosting.rootView = VoiceGlassPanelView(
            transcript: transcript, direction: direction, variant: .full)
    }
}

#endif
