import UIKit
import SwiftUI
import BentoTerminalCore

/// Manages the voice input gesture + recording lifecycle.
/// Added to a pane's terminal view as a long-press gesture recognizer.
///
/// Flow: hold >200ms → start recording → move finger → direction detection →
///       release → inject text based on direction
///
/// Two speech engines are supported and chosen per-recording from the
/// `speech_engine` user setting:
/// - "apple":  on-device `SFSpeechRecognizer` (no API key, may have lower
///   accuracy / language coverage; requires speech-recognition permission).
/// - "openai": cloud OpenAI Realtime API with `gpt-realtime-whisper`
///   (requires either `openai_api_key` direct BYOK, or `openai_proxy_url`
///   pointing at a token-mint server).
@MainActor
final class VoiceInputController: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var activeDirection: VoiceDirection = .none
    @Published var showOverlay = false
    @Published var fingerScreenPosition: CGPoint = .zero

    /// Right-swipe "transcribe → preview → edit → send" flow. `previewText` is the
    /// editable transcription shown in a sheet; `previewLoading` is true while the
    /// higher-accuracy batch model is still running.
    @Published var showPreview = false
    @Published var previewText = ""
    @Published var previewLoading = false

    /// Shared engine driver (engine selection + permissions + audio capture)
    /// lives in BentoTerminalCore so iOS + macOS run the same recording code.
    private let session = VoiceSession()

    private var holdOrigin: CGPoint = .zero
    private let directionThreshold: CGFloat = 40

    /// Called when voice input produces a result
    var onResult: ((VoiceInputResult) -> Void)?

    /// `VoiceInputResult` now lives in BentoTerminalCore; alias keeps existing
    /// `VoiceInputController.VoiceInputResult` references working.
    typealias VoiceInputResult = BentoTerminalCore.VoiceInputResult

    // MARK: - Tap-to-Toggle (mic button)

    /// Tap-to-toggle recording, anchored at a screen point (used for overlay
    /// placement). First tap starts recording; second tap stops + submits the
    /// transcript with no directional modifier (plain text inject).
    func toggleRecording(anchorScreenPoint: CGPoint) {
        if isRecording {
            stopRecording(direction: .none)
        } else {
            fingerScreenPosition = anchorScreenPoint
            holdOrigin = anchorScreenPoint
            startRecording()
        }
    }

    // MARK: - Gesture Handling

    func handleLongPress(state: UIGestureRecognizer.State, location: CGPoint) {
        switch state {
        case .began:
            // Anchor the compass overlay at the press origin and keep it there.
            // The compass's center "finger dot" + 4 directional arrows are laid
            // out at fixed offsets, so the whole thing must NOT track the
            // finger — otherwise the arrows move with the user and can never
            // be reached. Direction feedback is conveyed by highlighting the
            // active arrow, not by moving the overlay.
            holdOrigin = location
            fingerScreenPosition = location
            startRecording()

        case .changed:
            updateDirection(currentLocation: location)

        case .ended, .cancelled:
            let finalDirection = activeDirection
            stopRecording(direction: finalDirection)

        default:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        // Show overlay immediately for responsiveness.
        isRecording = true
        showOverlay = true
        transcript = ""
        activeDirection = .none
        HapticService.shared.prepare()
        HapticService.shared.recordingStarted()
        // The shared VoiceSession handles permissions + engine selection + audio.
        session.start(
            onPartial: { [weak self] text in self?.transcript = text },
            onError: { [weak self] message in Task { await self?.showTransientError(message) } })
    }

    private func showTransientError(_ message: String) async {
        dlog(message)
        // Release the mic engine + ASR on error so a failed session can't leave a
        // running engine that the next recording stacks a second tap onto.
        session.cancel()
        transcript = message
        isRecording = false
        try? await Task.sleep(for: .milliseconds(1200))
        showOverlay = false
    }

    // MARK: - Stop

    private func stopRecording(direction: VoiceDirection) {
        if direction == .down {
            session.cancel()
            isRecording = false
            HapticService.shared.cancelled()
            showOverlay = false
            return
        }

        if direction == .right {
            // New flow: re-transcribe the full clip with a better (non-realtime)
            // model, then let the user preview/edit before sending — instead of
            // inserting directly. (Left swipe still does NL→shell-command.) The
            // preview batches the captured PCM itself, so just stop capture here.
            let streamed = session.currentTranscript
            session.cancel()
            isRecording = false
            showOverlay = false
            beginPreview(streamed: streamed)
            return
        }

        // up / none / left → resolve the reliable final (await the realtime final,
        // batch-fallback so a quick release never drops the tail), with a brief
        // "识别中…" in the overlay while it lands.
        transcript = "识别中…"
        Task { [weak self] in
            guard let self else { return }
            let lang = openAILanguageHint(for: UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
            let text = await self.session.finish(language: lang)
            self.isRecording = false
            self.showOverlay = false
            guard !text.isEmpty else { return }
            HapticService.shared.sent()
            self.onResult?(VoiceInputResult(text: text, direction: direction))
        }
    }

    // MARK: - Preview (right-swipe)

    /// Open the editable preview seeded with the fast streamed transcript, then —
    /// if we captured the full audio (OpenAI engine) — replace it with a higher-
    /// accuracy batch transcription. On the Apple engine (no PCM) the user just
    /// edits the streamed text.
    private func beginPreview(streamed: String) {
        previewText = streamed
        let rec = session.takeRecordedPCM()
        previewLoading = (rec != nil)
        showPreview = true
        guard let rec else { return }
        Task {
            let lang = openAILanguageHint(for: UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
            let better = await BatchTranscriptionService.shared.transcribe(
                pcm: rec.pcm, sampleRate: rec.sampleRate, language: lang)
            await MainActor.run {
                if let better, !better.isEmpty { self.previewText = better }
                self.previewLoading = false
            }
        }
    }

    /// Send the (possibly edited) preview text to the active pane (insert + send).
    func sendPreview() {
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        showPreview = false
        previewLoading = false
        guard !text.isEmpty else { return }
        HapticService.shared.sent()
        onResult?(VoiceInputResult(text: text, direction: .up))
    }

    /// Dismiss the preview without sending.
    func cancelPreview() {
        showPreview = false
        previewLoading = false
        previewText = ""
    }

    // MARK: - Direction Detection

    private func updateDirection(currentLocation: CGPoint) {
        let dx = currentLocation.x - holdOrigin.x
        let dy = currentLocation.y - holdOrigin.y

        let newDirection: VoiceDirection
        if abs(dx) < directionThreshold && abs(dy) < directionThreshold {
            newDirection = .none
        } else if abs(dx) > abs(dy) {
            newDirection = dx > 0 ? .right : .left
        } else {
            newDirection = dy < 0 ? .up : .down
        }

        if newDirection != activeDirection {
            activeDirection = newDirection
            if newDirection != .none {
                HapticService.shared.directionChanged()
            }
        }
    }
}

// `TerminalViewModel.handleVoiceResult(_:)` now lives in BentoTerminalCore
// (shared by iOS + macOS).

/// Editable preview for the right-swipe voice flow: shows the higher-accuracy
/// batch transcription, lets the user fix it with the system keyboard, then send
/// it to the active pane. While the batch model is still running, the streamed
/// (rough) transcript is shown with a "recognizing" hint.
///
/// Lives here (not its own file) so it's picked up by the app target's source
/// list without a project.pbxproj edit.
struct VoicePreviewSheet: View {
    @ObservedObject var controller: VoiceInputController
    @FocusState private var focused: Bool

    private var isEmpty: Bool {
        controller.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $controller.previewText)
                    .font(.body)
                    .foregroundStyle(Color.bentoInk)
                    .scrollContentBackground(.hidden)
                    .background(Color.bentoSurface)
                    .focused($focused)
                    .padding(12)

                if controller.previewLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("识别中…")
                            .font(.footnote)
                            .foregroundStyle(Color.bentoInkDim)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 18)
                    .padding(.leading, 18)
                    .allowsHitTesting(false)
                }
            }
            .background(Color.bentoSurface)
            .navigationTitle("语音预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { controller.cancelPreview() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { controller.sendPreview() }
                        .fontWeight(.semibold)
                        .disabled(isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
