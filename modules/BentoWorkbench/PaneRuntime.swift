import BentoFoundation
import BentoUI
import ACPKit
import ACPHostKit
import Foundation

// Seam: the workspace store manages pane LIFECYCLE (spawn bookkeeping,
// reconnect, structure, catalog) without knowing what runs inside a pane.
// `PaneRuntime` is the store-facing face of that content; the pane module
// (today: the ACP agent module) supplies instances via `runtimeFactory`.
// Everything here speaks only workspace + host-transport vocabulary — no
// chat/transcript/provider types.

/// Lifecycle of a hosted pane runtime, as the store steers it.
///
/// This is `AgentSessionViewModel.Phase` hoisted to the workspace layer —
/// the store's reconnect/restart logic branches on it, so the vocabulary
/// belongs to the seam, not to the agent module.
public enum PaneRuntimePhase: Equatable, Sendable {
    case starting
    case ready
    /// The runtime answered auth_required: parked until authenticate /
    /// external sign-in re-runs establishment.
    case authRequired
    case failed(String)
    case ended
}

/// The store-facing surface of whatever runs inside a pane.
///
/// The store OWNS the pane's slot (keyed by pane id) and drives lifecycle:
/// establish, reconnect with backoff, restart, shutdown, rename, and raw
/// input routing. How the runtime renders, what its transcript looks like,
/// which protocol dialect it speaks — none of that appears here.
@MainActor
public protocol PaneRuntime: AnyObject {
    // Identity & titles (the store's title ladder reads these).
    var phase: PaneRuntimePhase { get }
    var title: String { get set }
    /// Runtime-reported conversation name (nil until the agent names it).
    var sessionTitle: String? { get }
    /// The established conversation id, once known.
    var sessionId: String? { get }

    // Catch-up cursor for attach/reattach (see acphost scrollback design).
    var updateSeq: UInt64 { get }
    /// Whether this client can honestly claim a rendered transcript — the
    /// daemon uses it (with the cursor) to decide whether to resend history.
    var holdsRenderedTranscript: Bool { get }

    // Establishment: the store launches/attaches via an `AgentLauncher` and
    // hands the results back to the runtime.
    func makeSessionHandler() -> any ACPClientHandler
    func bootstrap(connection: ACPConnection, resumeSessionId: String?) async
    func bootstrapAttached(launch: AgentLaunch, resumeSessionId: String?) async

    // Lifecycle verbs the store's restart/reconnect ladders drive.
    func prepareForRestart()
    func noteReconnectFailed()
    func noteLaunchFailure(_ message: String)
    func killAgent()
    func shutdown()

    // State-language inputs (working / awaiting / done-unseen).
    /// A turn is in flight — the "working" signal.
    var isTurnActive: Bool { get }
    /// The runtime is blocked on the user (permission card, elicitation…) —
    /// the "awaiting input" signal. `.authRequired` is judged via `phase`.
    var isAwaitingUserInput: Bool { get }
    /// One-line snippet of what the runtime is asking / last said — the
    /// awaiting-notification's prompt text; empty when there is nothing.
    var previewLine: String { get }

    // History-catalog inputs (the store's title ladder + lastActive stamps).
    /// First non-empty user prompt, trimmed, newlines collapsed — the
    /// history title fallback. nil while the transcript has none.
    var firstUserPromptPreview: String? { get }
    /// True once at least one turn has finished.
    var hasCompletedTurn: Bool { get }

    // Text input routing (`.textInput` capability): printable text lands in
    // the composer, CR submits — the voice compass's insert vs send.
    var composerDraft: String { get set }
    func send(_ text: String)
    func insertIntoComposer(_ text: String)
}
