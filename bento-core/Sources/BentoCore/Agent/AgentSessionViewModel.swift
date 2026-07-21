import ACPKit
import ACPHostKit
import Combine
import Foundation

/// An unanswered permission request. `respond` resumes the agent's
/// session/request_permission call exactly once.
@MainActor
public final class PermissionPrompt: Identifiable {
    public let id = UUID()
    public let request: RequestPermissionRequest
    private var respond: ((RequestPermissionOutcome) -> Void)?

    init(request: RequestPermissionRequest, respond: @escaping (RequestPermissionOutcome) -> Void) {
        self.request = request
        self.respond = respond
    }

    public func answer(_ outcome: RequestPermissionOutcome) {
        respond?(outcome)
        respond = nil
    }

    var isAnswered: Bool { respond == nil }
}

/// An unanswered elicitation (the agent asking the user structured
/// questions — Claude Code's AskUserQuestion arrives this way). `respond`
/// resumes the agent's elicitation/create call exactly once.
@MainActor
public final class ElicitationPrompt: Identifiable {
    public let id = UUID()
    public let request: CreateElicitationRequest
    /// Parsed form fields (form mode); nil for url/unknown modes.
    public let form: ElicitationForm?
    private var respond: ((CreateElicitationResponse) -> Void)?

    init(request: CreateElicitationRequest, respond: @escaping (CreateElicitationResponse) -> Void) {
        self.request = request
        self.form = request.mode == "form" ? ElicitationForm(requestedSchema: request.requestedSchema) : nil
        self.respond = respond
    }

    public func answer(_ response: CreateElicitationResponse) {
        respond?(response)
        respond = nil
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var usedTokens: Int?
    public var contextSize: Int?
    public var costAmount: Double?
    public var costCurrency: String?
}

/// An image staged in the composer, already downscaled/re-encoded for the
/// wire (agents take base64 in a JSON-RPC line).
public struct ComposerAttachment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var data: Data
    public var mimeType: String
    public var label: String

    init(data: Data, mimeType: String, label: String) {
        self.id = UUID()
        self.data = data
        self.mimeType = mimeType
        self.label = label
    }
}

/// A prompt written while a turn was still running; sent automatically when
/// the turn finishes (unless the user cancelled).
public struct QueuedMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var attachments: [ComposerAttachment]

    init(text: String, attachments: [ComposerAttachment] = []) {
        self.id = UUID()
        self.text = text
        self.attachments = attachments
    }
}

/// One agent session = one spawned agent process + one ACP session on it.
/// Pure state machine over session/update notifications; unit-tested without
/// a live connection.
@MainActor
public final class AgentSessionViewModel: ObservableObject, Identifiable {
    public enum Phase: Equatable {
        case starting
        case ready
        /// The agent answered auth_required: a live connection is parked and
        /// session creation re-runs after authenticate / external sign-in.
        case authRequired
        case failed(String)
        case ended
    }

    /// The agent is gone — its process exited / the connection closed
    /// (`.ended`) or it never started (`.failed`). Both are recoverable by a
    /// restart, so the UI surfaces the same restore affordance for either.
    public var isStopped: Bool {
        switch phase {
        case .ended, .failed: return true
        case .starting, .ready, .authRequired: return false
        }
    }

    public let id = UUID()
    public let preset: ACPAgentPreset
    public let cwd: String

    @Published public private(set) var items: [TranscriptItem] = []
    /// The agent message the cursor is currently over. A transient UI hint (not
    /// transcript state, hence weak + unpublished) so the macOS surface's
    /// right-click menu can scope "copy message / answer" to it — SwiftUI's own
    /// per-row context menu never fires there (the surface owns right-click).
    public weak var hoveredMessage: MessageItem?
    @Published public private(set) var plan: [PlanEntry] = []
    @Published public private(set) var phase: Phase = .starting
    @Published public private(set) var isTurnActive = false {
        didSet {
            guard isTurnActive != oldValue else { return }
            // Stamp when the turn began so the working indicator can show a
            // live elapsed timer. Mid-turn reattach lacks the original start,
            // so it counts from reattach — fine for a "still working" cue.
            turnStartedAt = isTurnActive ? Date() : nil
        }
    }
    /// When the current turn started; nil between turns. Drives the working
    /// indicator's elapsed-time readout.
    @Published public private(set) var turnStartedAt: Date?
    @Published public private(set) var pendingPermission: PermissionPrompt?
    @Published public private(set) var pendingElicitation: ElicitationPrompt?
    @Published public private(set) var modes: SessionModeState?
    @Published public private(set) var models: SessionModelState?
    /// Generic session knobs (model, effort, fast mode, …). The modern
    /// channel — when non-empty the strip renders these; the dedicated
    /// modes/models state stays as the fallback for agents still on it.
    @Published public private(set) var configOptions: [ConfigOption] = []
    @Published public private(set) var availableCommands: [AvailableCommand] = []
    @Published public private(set) var usage: UsageSnapshot?
    @Published public private(set) var queuedMessages: [QueuedMessage] = []
    @Published public private(set) var authMethods: [AuthMethodInfo] = []
    @Published public private(set) var promptCaps: PromptCapabilities?
    @Published public private(set) var composerAttachments: [ComposerAttachment] = []
    @Published public private(set) var lastStopReason: StopReason?
    /// Set by the workspace when a turn finishes while the session is not
    /// focused; cleared when the user views the session.
    @Published public var hasUnseenCompletion = false
    /// Composer draft lives on the session so voice (and future sources)
    /// can inject text exactly like the old pty insert did.
    @Published public var composerDraft = ""
    /// True while the client is trying to re-establish a dropped connection to
    /// a still-running daemon agent (a relay/socket blip, not a real exit). The
    /// transcript and pane stay put; only the connection is being rebuilt.
    @Published public private(set) var isReconnecting = false

    public private(set) var sessionId: String?
    /// Daemon-side instance id for persistent agents (attach/reattach).
    public private(set) var agentID: String?
    @Published public var title: String
    /// The agent-side conversation name (session_info_update: the user's
    /// /rename, else the agent's auto-generated summary). Seeded from the
    /// history catalog on respawn; the agent re-sends it at turn end.
    @Published public internal(set) var sessionTitle: String?

    /// Workspace hook, fired on any activity-state-relevant change.
    var onActivityChange: (@MainActor () -> Void)?

    /// Workspace hook: the agent renamed the conversation — pane titles and
    /// the history catalog want a refresh.
    var onSessionTitleChange: (@MainActor () -> Void)?

    /// Workspace hook: resuming a recorded ACP session drew an agent-side
    /// RPC error — the conversation was likely GC'd. The store marks the
    /// history-catalog entry expired.
    var onSessionLoadFailed: (@MainActor (String) -> Void)?

    /// Workspace hook: the user asked to revive a stopped/failed pane from the
    /// restart affordance. The store re-establishes THIS runtime in place.
    var onRestartRequested: (@MainActor () -> Void)?

    /// Workspace hook: the live connection to a daemon-hosted agent dropped at
    /// runtime WITHOUT the agent having exited (a relay/socket blip — the agent
    /// process is still alive in the daemon). The store reattaches with backoff
    /// instead of declaring the agent dead.
    var onConnectionLost: (@MainActor () -> Void)?

    /// Fires on ANY transcript content growth — new items and in-place growth
    /// (streaming flushes, tool merges) alike. The transcript's auto-follow
    /// subscribes to the throttled pulse; item-count changes alone miss all
    /// in-place growth.
    let transcriptDidGrow = PassthroughSubject<Void, Never>()
    public private(set) lazy var transcriptGrowthPulse: AnyPublisher<Void, Never> =
        transcriptDidGrow
        .throttle(for: .milliseconds(90), scheduler: RunLoop.main, latest: true)
        .eraseToAnyPublisher()

    private var connection: ACPConnection?
    private var hostTransport: AcpHostTransport?
    /// The client handler for the CURRENT connection. Retained so that when a
    /// restart supersedes it, the stale bridge can be neutered — a superseded
    /// connection's late callbacks (close, updates, permission) then can't
    /// touch this session and corrupt the fresh conversation.
    private var bridge: SessionConnectionBridge?
    private var toolItems: [String: ToolCallItem] = [:]
    private var streamingAgentMessage: MessageItem?
    private var streamingThought: MessageItem?
    private var replayUserMessage: MessageItem?
    /// True while `session/load` is streaming the WHOLE conversation back as
    /// `session/update` notifications. `session/load` has no pagination, so a
    /// months-long daemon session replays thousands of items at once. During
    /// replay these accumulate in `replayBuffer`/`replayPlan` and land in the
    /// published `items`/`plan` in ONE mutation (see begin/endReplay) — a long
    /// history costs a single SwiftUI invalidation, not one per item (which
    /// froze the main thread on resume).
    private var isReplaying = false
    private var replayBuffer: [TranscriptItem] = []
    private var replayPlan: [PlanEntry] = []
    /// Attached while a detached-started turn was still running; history
    /// backfills (session/load) once that turn completes.
    private var attachedMidTurn = false
    /// Re-runs session establishment after a successful authenticate (or an
    /// external sign-in + Retry) while the connection is parked.
    private var pendingEstablish: (() async -> Void)?
    /// Last agent stderr lines (daemon-hosted agents); attached to the
    /// death/failed notice so a misbehaving agent leaves a trace.
    private var stderrTail: [String] = []
    /// The last stderr line surfaced to the transcript, so a repeated line
    /// (retry/spinner spam) isn't printed twice in a row. Reset when a
    /// fresh turn starts.
    private var lastSurfacedStderr: String?

    public init(preset: ACPAgentPreset, cwd: String) {
        self.preset = preset
        self.cwd = cwd
        self.title = (cwd as NSString).lastPathComponent
    }

    /// What we tell agents we can do. Elicitation-form is load-bearing:
    /// claude-agent-acp disables AskUserQuestion entirely for clients that
    /// don't advertise it.
    static let clientCapabilities = ClientCapabilities(
        fs: FileSystemCapability(readTextFile: false, writeTextFile: false),
        terminal: false,
        elicitation: ElicitationCapability(form: .init()))

    public var activityState: SessionActivityState {
        if pendingPermission != nil || pendingElicitation != nil || phase == .authRequired {
            return .awaiting
        }
        if isTurnActive || phase == .starting { return .working }
        if hasUnseenCompletion { return .doneUnseen }
        return .idle
    }

    /// Recent transcript text for ASR vocabulary biasing (the ACP analogue
    /// of the old on-screen-context corpus).
    public var recentTranscriptText: String {
        var pieces: [String] = []
        var total = 0
        for item in items.reversed() {
            var text = ""
            if let message = item as? MessageItem {
                text = message.fullText
            } else if let tool = item as? ToolCallItem {
                text = tool.title
            }
            guard !text.isEmpty else { continue }
            pieces.append(text)
            total += text.count
            if total > 4000 { break }
        }
        return pieces.reversed().joined(separator: "\n").suffix(4000).description
    }

    /// One-line snippet for compact cards (iPhone tiled grid): the pending
    /// permission, else the tail of the latest message.
    public var previewLine: String {
        if let permission = pendingPermission {
            return permission.request.toolCall.title ?? "Waiting for permission"
        }
        if let elicitation = pendingElicitation {
            return elicitation.request.message
        }
        if isReconnecting { return "Reconnecting…" }
        for item in items.reversed() {
            if let message = item as? MessageItem, message.role != .thought {
                let text = message.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return String(text.prefix(120)) }
            }
            if let tool = item as? ToolCallItem {
                return tool.title
            }
        }
        switch phase {
        case .starting: return "Starting…"
        case .authRequired: return "Sign-in required"
        case .failed(let reason): return reason
        case .ended: return "Agent exited"
        case .ready: return "Ready"
        }
    }

    // MARK: - Lifecycle

    /// Attach a live connection and create (or resume) the ACP session.
    public func bootstrap(connection: ACPConnection, resumeSessionId: String? = nil) async {
        self.connection = connection
        do {
            let initResp = try await connection.initialize(clientCapabilities: Self.clientCapabilities)
            guard initResp.protocolVersion >= 1 else {
                throw ACPError.malformedMessage("unsupported protocol \(initResp.protocolVersion)")
            }
            authMethods = initResp.authMethods ?? []
            promptCaps = initResp.agentCapabilities?.promptCapabilities
            let loadSupported = initResp.agentCapabilities?.loadSession == true
            await runEstablish(failurePrefix: "Failed to start \(preset.name)") { [weak self] in
                guard let self else { return }
                if let resumeSessionId, loadSupported {
                    let resp = try await self.loadSessionReportingFailure(
                        sessionId: resumeSessionId)
                    self.sessionId = resumeSessionId
                    self.modes = resp.modes
                    self.models = resp.models
                    self.configOptions = resp.configOptions ?? []
                } else {
                    let resp = try await self.requireConnection().newSession(cwd: self.cwd)
                    self.sessionId = resp.sessionId
                    self.modes = resp.modes
                    self.models = resp.models
                    self.configOptions = resp.configOptions ?? []
                }
                self.closeStreams()
            }
        } catch {
            phase = .failed(describe(error))
            appendNotice(.error, "Failed to start \(preset.name): \(describe(error))")
        }
        onActivityChange?()
    }

    /// Bootstrap against a daemon-hosted (persistent) agent: fresh spawn or
    /// reattach. History rebuilds through session/load; attaching mid-turn
    /// defers that until the running turn completes. `resumeSessionId` is the
    /// recorded ACP session for a RESPAWNED process (its predecessor died
    /// with a daemon restart) — the agent's own storage still holds the
    /// conversation, so loading it revives the pane.
    public func bootstrapAttached(launch: AgentLaunch, resumeSessionId: String? = nil) async {
        resetTranscript()
        connection = launch.connection
        hostTransport = launch.transport
        agentID = launch.attachInfo?.agentID
        bindTransportEvents()
        do {
            guard let connection else { throw ACPError.transportClosed }
            let initResp = try await connection.initialize(clientCapabilities: Self.clientCapabilities)
            guard initResp.protocolVersion >= 1 else {
                throw ACPError.malformedMessage("unsupported protocol \(initResp.protocolVersion)")
            }
            authMethods = initResp.authMethods ?? []
            promptCaps = initResp.agentCapabilities?.promptCapabilities
            if let known = launch.attachInfo?.acpSessionID, !known.isEmpty {
                sessionId = known
            } else if let resumeSessionId, !resumeSessionId.isEmpty,
                      initResp.agentCapabilities?.loadSession == true {
                sessionId = resumeSessionId
            }
            // Load the prior conversation for BOTH a settled and a mid-turn
            // attach. A mid-turn `session/load` returns only PERSISTED history
            // (completed turns + this turn's prompt) as a block that lands
            // BEFORE its response, and the agent resumes the live turn's chunks
            // only after — so they keep appending cleanly, no interleave. This
            // is what lets a long-running task show its history the moment you
            // attach instead of staying blind until the turn ends. The boundary
            // is the load RESPONSE (ordering, not a timer), so it holds on the
            // slow iOS relay exactly as on the local socket. Mid-turn keeps the
            // stream open and stays turn-active; the current turn's pre-attach
            // output stays a gap the turn-end backfill fills in.
            if launch.attachInfo?.turnActive == true {
                attachedMidTurn = true
                isTurnActive = true
                phase = .ready
                if let sid = sessionId {
                    do {
                        let resp = try await loadSessionReportingFailure(sessionId: sid)
                        modes = resp.modes
                        models = resp.models
                        configOptions = resp.configOptions ?? []
                        // No closeStreams(): the live turn keeps appending.
                    } catch {
                        // The agent couldn't serve history mid-turn (not every
                        // agent can). The live stream is healthy — keep the
                        // pane alive; the turn-end backfill recovers history.
                        appendNotice(.info, "Full history loads when this turn completes.")
                    }
                }
            } else {
                await runEstablish(failurePrefix: "Failed to attach \(preset.name)") { [weak self] in
                    guard let self else { return }
                    if let sid = self.sessionId {
                        let resp = try await self.loadSessionReportingFailure(sessionId: sid)
                        self.modes = resp.modes
                        self.models = resp.models
                        self.configOptions = resp.configOptions ?? []
                        self.closeStreams()
                    } else {
                        let resp = try await self.requireConnection().newSession(cwd: self.cwd)
                        self.sessionId = resp.sessionId
                        self.modes = resp.modes
                        self.models = resp.models
                        self.configOptions = resp.configOptions ?? []
                    }
                }
            }
        } catch {
            phase = .failed(describe(error))
            appendNotice(.error, "Failed to attach \(preset.name): \(describe(error))")
        }
        onActivityChange?()
    }

    // MARK: - Establish / auth

    private func requireConnection() throws -> ACPConnection {
        guard let connection else { throw ACPError.transportClosed }
        return connection
    }

    /// session/load with expiry detection: an agent-side RPC error (as
    /// opposed to a transport failure) most likely means the agent no longer
    /// holds this conversation. Coarse — ACP has no standard "session not
    /// found" code to match on. TODO: refine per-agent when codes settle.
    private func loadSessionReportingFailure(sessionId: String) async throws -> LoadSessionResponse {
        // All three resume paths (bootstrap, bootstrapAttached, mid-turn
        // backfill) funnel through here, so bracketing the replay here batches
        // every one of them. `defer` also flushes a partial history on failure.
        beginReplay()
        defer { endReplay() }
        do {
            return try await requireConnection().loadSession(sessionId: sessionId, cwd: cwd)
        } catch {
            if case ACPError.rpc = error { onSessionLoadFailed?(sessionId) }
            throw error
        }
    }

    /// Enter history-replay mode. Resets the incremental accumulators so
    /// replay rebuilds from scratch — which also makes a retried load (e.g.
    /// after auth) idempotent: it can't stack a second copy of the history.
    /// The visible `items`/`plan` are left untouched and swapped atomically by
    /// `endReplay`, so there's no empty flash mid-load (matters on the slower
    /// iOS relay transport).
    private func beginReplay() {
        isReplaying = true
        replayBuffer.removeAll()
        replayPlan = []
        toolItems.removeAll()
        streamingAgentMessage = nil
        streamingThought = nil
        replayUserMessage = nil
    }

    /// Leave replay mode: publish the whole buffered history in one mutation.
    /// A failed load flushes an empty buffer (transcript clears) — the same
    /// outcome the old reset-then-append path produced.
    private func endReplay() {
        guard isReplaying else { return }
        isReplaying = false
        items = replayBuffer
        plan = replayPlan
        replayBuffer.removeAll()
        replayPlan = []
        // Replayed messages are complete history — close the trailing streaming
        // one so a following LIVE chunk (mid-turn attach keeps the stream open)
        // starts a fresh message instead of being glued onto loaded history.
        // A mid-turn replay ends with the running turn's own PROMPT, so the
        // trailing user message needs the same closing (and envelope check).
        finishReplayUserMessage()
        streamingAgentMessage?.finishStreaming()
        streamingAgentMessage = nil
        streamingThought?.finishStreaming()
        streamingThought = nil
        transcriptDidGrow.send()
    }

    /// Run a session-establishment step. auth_required parks the step for
    /// re-running after sign-in instead of failing the pane.
    private func runEstablish(
        failurePrefix: String, _ step: @escaping @MainActor () async throws -> Void
    ) async {
        do {
            try await step()
            pendingEstablish = nil
            isReconnecting = false
            phase = .ready
        } catch {
            if isAuthRequired(error) {
                let firstAsk = phase != .authRequired
                pendingEstablish = { [weak self] in
                    await self?.runEstablish(failurePrefix: failurePrefix, step)
                }
                // Reconnect handed off to sign-in — it's the user's move now,
                // not another retry.
                isReconnecting = false
                phase = .authRequired
                if firstAsk {
                    appendNotice(.info, "\(preset.name) needs sign-in before it can start a session.")
                } else {
                    appendNotice(.error, "Still not signed in: \(describe(error))")
                }
            } else {
                phase = .failed(describe(error))
                appendNotice(.error, "\(failurePrefix): \(describe(error))")
            }
        }
        onActivityChange?()
    }

    private func isAuthRequired(_ error: Error) -> Bool {
        if case ACPError.rpc(let obj) = error { return obj.code == JSONRPCErrorObject.authRequired }
        return false
    }

    /// In-protocol authenticate with one of the agent's advertised methods,
    /// then re-run session establishment. Vendor logins that are interactive
    /// (OAuth in a terminal) fail here — the auth card then points at the
    /// preset's loginHint and Retry.
    public func authenticate(methodId: String) {
        guard phase == .authRequired, let connection else { return }
        Task { @MainActor [weak self] in
            do {
                try await connection.authenticate(methodId: methodId)
                await self?.retryEstablish()
            } catch {
                guard let self else { return }
                self.appendNotice(.error, "Sign-in failed: \(self.describe(error))")
                if let hint = self.preset.loginHint {
                    self.appendNotice(
                        .info, "Run `\(hint)` in a terminal on the host, then hit Retry.")
                }
            }
        }
    }

    /// Re-attempt session establishment (after external sign-in).
    public func retryEstablish() async {
        guard phase == .authRequired, let pendingEstablish else { return }
        await pendingEstablish()
    }

    private func bindTransportEvents() {
        hostTransport?.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleHostEvent(event)
            }
        }
    }

    // internal (not private) so tests can drive the daemon/detached turn-end
    // arm directly — there's no scripted host-transport to emit it otherwise.
    func handleHostEvent(_ event: AcpHostEvent) {
        switch event {
        case .agentExited:
            break  // The transport finishes `incoming`; connectionDidClose reports it.
        case .detachedByAnotherClient:
            appendNotice(.info, "Session opened on another device — detached here.")
            shutdown()
        case .turnFinishedWhileDetached(let stopReason):
            let reason = StopReason(rawValue: stopReason) ?? .endTurn
            isTurnActive = false
            lastStopReason = reason
            if attachedMidTurn {
                attachedMidTurn = false
                // Load the finished turn's final transcript, THEN release any
                // queued prompt so its new turn builds on a settled history.
                Task { [weak self] in
                    await self?.refreshFromHistory()
                    if reason != .cancelled { self?.flushQueue() }
                }
            } else if reason != .cancelled {
                // The daemon/detached turn-end is the real runtime's turn end;
                // finishTurn() (which drains the queue) never runs on this path,
                // so flush here too — matching its "don't auto-release after a
                // cancel" rule.
                flushQueue()
            }
            onActivityChange?()
        case .stderrLine(let line):
            stderrTail.append(line)
            if stderrTail.count > 50 { stderrTail.removeFirst(stderrTail.count - 50) }
            // While a turn is in flight, surface the agent's raw stderr so a
            // stall (e.g. a usage limit that leaves the agent neither
            // answering the prompt nor exiting) isn't silent. Shown verbatim
            // — no classifying — skipping only blank lines, back-to-back
            // repeats, and known-benign harness chatter (still kept in
            // `stderrTail` above for diagnostics).
            if isTurnActive {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != lastSurfacedStderr,
                   !Self.isBenignAgentLog(trimmed) {
                    lastSurfacedStderr = trimmed
                    appendNotice(.error, trimmed)
                }
            }
        case .stateChanged:
            break  // Workspace-structure sync is the store's concern.
        }
    }

    /// Rebuild the transcript from the agent's own conversation storage.
    /// The reset is folded into the load's replay bracket (begin/endReplay),
    /// so the current transcript stays on screen until the reload is ready.
    private func refreshFromHistory() async {
        guard connection != nil, let sid = sessionId else { return }
        // The agent may not have flushed the just-finished turn to its session
        // store the instant it reports the turn done, so a load fired
        // immediately can come back SHORT — and the replay REPLACES the
        // transcript, dropping the tail we just watched stream in mid-turn.
        // Snapshot that tail, load after a beat, and re-load (bounded backoff)
        // until the history covers it. If it never does, keep the live capture
        // rather than leave a hole in what the user already saw.
        let liveItems = items
        let liveTail = Self.lastAgentText(in: liveItems)
        for attempt in 0..<3 {
            try? await Task.sleep(nanoseconds: 500_000_000 + UInt64(attempt) * 450_000_000)
            guard connection != nil, sessionId == sid else { return }
            do {
                let resp = try await loadSessionReportingFailure(sessionId: sid)
                modes = resp.modes
                models = resp.models
                configOptions = resp.configOptions ?? []
            } catch {
                appendNotice(.error, "History reload failed: \(describe(error))")
                return
            }
            if liveTail == nil || (Self.lastAgentText(in: items)?.contains(liveTail!) ?? false) {
                closeStreams()
                return
            }
        }
        // Never caught up: restore the live capture so the tail isn't lost.
        if let liveTail, !(Self.lastAgentText(in: items)?.contains(liveTail) ?? false) {
            items = liveItems
        }
        closeStreams()
    }

    /// The trailing agent message's text in `items`, if any — lets the mid-turn
    /// backfill tell whether a history reload has caught up to what streamed in.
    private static func lastAgentText(in items: [TranscriptItem]) -> String? {
        for item in items.reversed() {
            if let m = item as? MessageItem, m.role == .agent {
                let t = m.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private func resetTranscript() {
        items.removeAll()
        toolItems.removeAll()
        streamingAgentMessage = nil
        streamingThought = nil
        replayUserMessage = nil
        plan = []
    }

    /// Kill the daemon-side agent (user closed the session).
    public func killAgent() {
        hostTransport?.killAgent(id: agentID)
    }

    /// Read a file for preview. On the Mac the file is local; on iOS it
    /// lives on the paired Mac and comes through the host transport.
    public func readFile(_ path: String) async throws -> String {
        #if os(macOS)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        guard data.count <= 2 << 20 else {
            throw ACPError.malformedMessage("file too large to preview (>2 MiB)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ACPError.malformedMessage("binary file")
        }
        return text
        #else
        guard let hostTransport else { throw ACPError.transportClosed }
        return try await hostTransport.readFile(path)
        #endif
    }

    public func shutdown() {
        let connection = connection
        self.connection = nil
        hostTransport = nil
        Task { await connection?.close() }
        if phase == .ready || phase == .starting || phase == .authRequired { phase = .ended }
    }

    // MARK: - Restart

    /// Mint the client handler for a fresh connection, neutering any prior one
    /// so a superseded connection (e.g. the dead one we're restarting away
    /// from) can't deliver a late close/update into the new conversation. The
    /// store hands the returned bridge to the launcher.
    func makeBridge() -> SessionConnectionBridge {
        bridge?.session = nil
        let fresh = SessionConnectionBridge()
        fresh.session = self
        bridge = fresh
        return fresh
    }

    /// User tapped the restore affordance on a stopped/failed pane.
    public func requestRestart() { onRestartRequested?() }

    /// Return a stopped/failed pane to a pre-bootstrap state so the SAME object
    /// can be re-established in place — the surfaces bind the runtime by
    /// identity, so reusing it keeps the view wired and the transcript on
    /// screen until the resumed history swaps in. Called by the store right
    /// before it re-drives `bootstrap`.
    func prepareForRestart() {
        let old = connection
        connection = nil
        hostTransport = nil
        Task { await old?.close() }
        closeStreams()
        isTurnActive = false
        attachedMidTurn = false
        queuedMessages.removeAll()
        stderrTail.removeAll()
        pendingEstablish = nil
        isReconnecting = false
        phase = .starting
    }

    // MARK: - User actions

    // MARK: - Slash-command completion

    /// Commands matching the draft while it is still a bare "/prefix" (no
    /// space yet — once arguments start the panel goes away). Shared by the
    /// composer (key handling) and the pane host that renders the panel.
    public var slashCommandMatches: [AvailableCommand] {
        slashCommandMatches(for: composerDraft)
    }

    /// Match against an EXPLICIT draft — the pane host presents the panel
    /// synchronously from the `$composerDraft` emission (whose new value it
    /// gets here), before the property's willSet has landed, to skip the
    /// main-queue hop that stuck the panel behind heavy renders.
    public func slashCommandMatches(for draft: String) -> [AvailableCommand] {
        guard phase == .ready, draft.hasPrefix("/"),
            !draft.contains(" "), !draft.contains("\n"), !availableCommands.isEmpty
        else { return [] }
        let prefix = draft.dropFirst().lowercased()
        guard !prefix.isEmpty else { return availableCommands }
        let matched = availableCommands.filter { $0.name.lowercased().hasPrefix(prefix) }
        // Fully-typed unique command: completion has nothing left to add.
        if matched.count == 1, matched[0].name.lowercased() == prefix { return [] }
        return matched
    }

    /// The draft's leading "/command" token when it names an available command
    /// exactly — drives the composer field's accent highlight.
    public var recognizedCommandToken: String? {
        guard composerDraft.hasPrefix("/") else { return nil }
        let name = composerDraft.dropFirst().prefix { !$0.isWhitespace }
        guard !name.isEmpty,
            availableCommands.contains(where: { $0.name.lowercased() == name.lowercased() })
        else { return nil }
        return "/" + name
    }

    /// Accept a completion: commands that take input get a trailing space for
    /// the argument; bare commands are left ready to send with ⏎.
    public func acceptSlashCommand(_ command: AvailableCommand) {
        composerDraft = "/\(command.name)" + (command.input != nil ? " " : "")
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composerAttachments
        guard !trimmed.isEmpty || !attachments.isEmpty, phase == .ready,
            connection != nil, sessionId != nil
        else { return }
        composerAttachments = []
        if isTurnActive {
            queuedMessages.append(QueuedMessage(text: trimmed, attachments: attachments))
            return
        }
        performSend(text: trimmed, attachments: attachments)
    }

    private func performSend(text: String, attachments: [ComposerAttachment]) {
        guard let connection, let sessionId else { return }
        let item = MessageItem(role: .user, text: text, images: attachments.map(\.data))
        appendItem(item)
        isTurnActive = true
        lastStopReason = nil
        lastSurfacedStderr = nil
        onActivityChange?()
        var blocks: [ContentBlock] = attachments.map {
            .image(data: $0.data.base64EncodedString(), mimeType: $0.mimeType)
        }
        if !text.isEmpty { blocks.append(.text(text)) }
        Task { [weak self] in
            do {
                let resp = try await connection.prompt(sessionId: sessionId, blocks: blocks)
                await MainActor.run { self?.finishTurn(resp.stopReason) }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if self.phase == .ready {
                        self.appendNotice(.error, "Turn failed: \(self.describe(error))")
                    }
                    self.finishTurn(nil)
                }
            }
        }
    }

    /// Stage an image for the next prompt. No-op unless the agent's
    /// promptCapabilities allow images. Data is downscaled/re-encoded before
    /// staging (base64 rides a JSON-RPC line).
    public func attachImage(data: Data, label: String = "Image") {
        guard promptCaps?.image == true else { return }
        guard let processed = ImageAttachmentProcessor.process(data) else {
            appendNotice(.error, "Couldn't read that image.")
            return
        }
        composerAttachments.append(
            ComposerAttachment(data: processed.data, mimeType: processed.mimeType, label: label))
    }

    public func removeAttachment(_ id: UUID) {
        composerAttachments.removeAll { $0.id == id }
    }

    public var canAttachImages: Bool { promptCaps?.image == true }

    public func cancelTurn() {
        guard isTurnActive, let connection, let sessionId else { return }
        // Spec: a cancelling client must answer pending permission requests
        // with cancelled. Same treatment for an open elicitation.
        pendingPermission?.answer(.cancelled)
        pendingPermission = nil
        pendingElicitation?.answer(.cancel)
        pendingElicitation = nil
        Task { try? await connection.cancel(sessionId: sessionId) }
    }

    public func respondPermission(_ outcome: RequestPermissionOutcome) {
        pendingPermission?.answer(outcome)
        pendingPermission = nil
        onActivityChange?()
    }

    public func respondElicitation(_ response: CreateElicitationResponse) {
        pendingElicitation?.answer(response)
        pendingElicitation = nil
        onActivityChange?()
    }

    public func removeQueuedMessage(_ id: UUID) {
        queuedMessages.removeAll { $0.id == id }
    }

    /// Send a queued message immediately (chip tap while the session is idle).
    public func sendQueuedMessageNow(_ id: UUID) {
        guard !isTurnActive, phase == .ready,
            let index = queuedMessages.firstIndex(where: { $0.id == id })
        else { return }
        let message = queuedMessages.remove(at: index)
        performSend(text: message.text, attachments: message.attachments)
    }

    private func flushQueue() {
        guard !isTurnActive, phase == .ready, !queuedMessages.isEmpty else { return }
        let next = queuedMessages.removeFirst()
        performSend(text: next.text, attachments: next.attachments)
    }

    public func setMode(_ modeId: String) {
        guard let connection, let sessionId else { return }
        Task { [weak self] in
            do {
                try await connection.setSessionMode(sessionId: sessionId, modeId: modeId)
                await MainActor.run { self?.modes?.currentModeId = modeId }
            } catch { /* agent refused; UI unchanged */ }
        }
    }

    public func setModel(_ modelId: String) {
        guard let connection, let sessionId else { return }
        Task { [weak self] in
            do {
                try await connection.setSessionModel(sessionId: sessionId, modelId: modelId)
                await MainActor.run { self?.models?.currentModelId = modelId }
            } catch { /* unsupported */ }
        }
    }

    /// Switch a generic session knob (model, effort, …). The response carries
    /// the refreshed full list — adopt it wholesale, since one change can
    /// reshape sibling options (a model switch rebuilds the effort list).
    public func setConfigOption(id: String, value: String) {
        guard let connection, let sessionId else { return }
        Task { [weak self] in
            do {
                let resp = try await connection.setSessionConfigOption(
                    sessionId: sessionId, configId: id, value: .string(value))
                await MainActor.run {
                    guard let self else { return }
                    if let options = resp.configOptions {
                        self.configOptions = options
                    } else if let index = self.configOptions.firstIndex(where: { $0.id == id }) {
                        self.configOptions[index].currentValue = .string(value)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.appendNotice(.error, "Couldn't change \(id): \(self.describe(error))")
                }
            }
        }
    }

    /// Apply a voice result per the compass direction — the ACP mapping of
    /// the old handleVoiceResult (insert / insert+send; left's NL→shell
    /// conversion has no shell to target, so it inserts the utterance).
    public func handleVoiceResult(_ result: VoiceInputResult) {
        switch result.direction {
        case .none, .left:
            insertIntoComposer(result.text)
        case .up, .right:
            send(result.text)
        case .down:
            break
        }
    }

    public func insertIntoComposer(_ text: String) {
        if composerDraft.isEmpty {
            composerDraft = text
        } else {
            composerDraft += (composerDraft.hasSuffix(" ") ? "" : " ") + text
        }
    }

    public func markSeen() {
        hasUnseenCompletion = false
        onActivityChange?()
    }

    // MARK: - Update handling (called by the connection bridge)

    func handle(_ notification: SessionNotification) {
        guard notification.sessionId == sessionId || sessionId == nil else { return }
        switch notification.update {
        case .userMessageChunk(let block):
            handleUserChunk(block)
        case .agentMessageChunk(let block):
            appendStreaming(role: .agent, block: block)
        case .agentThoughtChunk(let block):
            appendStreaming(role: .thought, block: block)
        case .toolCall(let update):
            closeStreams()
            if let existing = toolItems[update.toolCallId] {
                existing.merge(update)
            } else {
                let item = ToolCallItem(update: update)
                toolItems[update.toolCallId] = item
                appendItem(item)
            }
        case .toolCallUpdate(let update):
            if let existing = toolItems[update.toolCallId] {
                existing.merge(update)
            } else {
                let item = ToolCallItem(update: update)
                toolItems[update.toolCallId] = item
                appendItem(item)
            }
        case .plan(let entries):
            if isReplaying { replayPlan = entries } else { plan = entries }
        case .availableCommandsUpdate(let commands):
            availableCommands = commands
        case .currentModeUpdate(let modeId):
            modes?.currentModeId = modeId
            // Keep the generic strip in sync when the mode change came from
            // outside the config path (e.g. a /command or agent-side switch).
            if let index = configOptions.firstIndex(where: { $0.id == "mode" }) {
                configOptions[index].currentValue = .string(modeId)
            }
        case .configOptionUpdate(let options):
            configOptions = options
        case .unknown(let type, let payload):
            handleUnknown(type: type, payload: payload)
        }
    }

    func presentPermission(
        _ request: RequestPermissionRequest, respond: @escaping (RequestPermissionOutcome) -> Void
    ) {
        // A second request while one is pending would deadlock the UI;
        // reject it defensively (agents send one at a time in practice).
        if pendingPermission != nil {
            respond(.cancelled)
            return
        }
        pendingPermission = PermissionPrompt(request: request, respond: respond)
        onActivityChange?()
    }

    func presentElicitation(
        _ request: CreateElicitationRequest, respond: @escaping (CreateElicitationResponse) -> Void
    ) {
        // One at a time, same defensive posture as permissions.
        if pendingElicitation != nil {
            respond(.cancel)
            return
        }
        pendingElicitation = ElicitationPrompt(request: request, respond: respond)
        onActivityChange?()
    }

    /// The live ACP connection ended. Distinguishes a recoverable transport
    /// drop from a real agent exit:
    ///   • `error != nil` — the transport threw (relay stream reset, socket
    ///     dropped). For a daemon-hosted agent (`agentID != nil`) the process
    ///     is still alive on the Mac; reattach with backoff rather than
    ///     declaring it dead. This is the fix for phones flashing "agent
    ///     exited" every time the daemon's relay link blips or reconnects.
    ///   • `error == nil` — the stream finished cleanly: the daemon sent an
    ///     `exit` control (real process exit) or we closed locally. Terminal.
    func handleConnectionDropped(error: Error?) {
        let recoverable = error != nil && agentID != nil && onConnectionLost != nil
            && (phase == .ready || phase == .starting || phase == .authRequired)
        guard recoverable else {
            handleConnectionClosed(error: error)
            return
        }
        pendingPermission?.answer(.cancelled)
        pendingPermission = nil
        pendingElicitation?.answer(.cancel)
        pendingElicitation = nil
        closeStreams()
        isTurnActive = false
        if !isReconnecting {
            isReconnecting = true
            appendNotice(.info, "Connection lost — reconnecting to the agent…")
        }
        // .starting reads as "working" to the activity model, so the pane shows
        // a live/working state (not a stopped one) while we reattach.
        phase = .starting
        onConnectionLost?()
        onActivityChange?()
    }

    /// Auto-reconnect gave up after exhausting its retries. The agent may well
    /// still be alive on the Mac — this is a "couldn't get back to it" state,
    /// NOT an "agent exited", so it gets its own honest wording. Still lands in
    /// `.ended` so the pane offers the restore/reconnect affordance.
    func noteReconnectFailed() {
        isReconnecting = false
        closeStreams()
        isTurnActive = false
        if phase == .ready || phase == .starting || phase == .authRequired {
            phase = .ended
            appendNotice(
                .error,
                "Lost the connection to the agent. It may still be running on the Mac — tap to reconnect.",
                detail: stderrTail.isEmpty ? nil : stderrTail.suffix(20).joined(separator: "\n"))
        }
        onActivityChange?()
    }

    func handleConnectionClosed(error: Error?) {
        isReconnecting = false
        pendingPermission?.answer(.cancelled)
        pendingPermission = nil
        pendingElicitation?.answer(.cancel)
        pendingElicitation = nil
        closeStreams()
        if isTurnActive { isTurnActive = false }
        if phase == .ready || phase == .starting || phase == .authRequired {
            phase = .ended
            appendNotice(
                .error, "Agent exited\(error.map { ": \(describe($0))" } ?? "")",
                detail: stderrTail.isEmpty ? nil : stderrTail.suffix(20).joined(separator: "\n"))
        }
        onActivityChange?()
    }

    // MARK: - Internals

    /// Tags an agent's harness wraps around synthetic user-role turns it
    /// injects into the conversation (Claude Code and kin) — background-task
    /// notifications, system reminders, slash-command echoes, local-command
    /// output. The agent stores these as real user turns, so `session/load`
    /// replays them, but they aren't something the user typed.
    private static let harnessEnvelopeTags: Set<String> = [
        "task-notification", "system-reminder", "system-warning",
        "command-name", "command-message", "command-args", "command-output",
        "local-command-stdout", "local-command-stderr", "local-command-caveat",
        "bash-input", "bash-stdout", "bash-stderr",
    ]

    /// True when the whole user turn is a harness envelope: it opens with one
    /// of `harnessEnvelopeTags`. A locally-typed prompt never leads with one,
    /// and this only ever runs on replayed turns, so real input is untouched.
    private static func isHarnessEnvelope(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), !trimmed.hasPrefix("</") else { return false }
        let name = trimmed.dropFirst().prefix { c in
            c != " " && c != ">" && c != "/" && c != "\n" && c != "\t" && c != "\r"
        }
        return harnessEnvelopeTags.contains(name.lowercased())
    }

    private func handleUserChunk(_ block: ContentBlock) {
        // Locally-sent prompts already appear in the transcript; user chunks
        // only matter when replaying history via session/load. During a
        // MID-TURN attach the turn is active while the load replays — the
        // replayed chunks include the running turn's own prompt (the newest
        // user message), so replay must win over the turn-active guard.
        guard !isTurnActive || isReplaying else { return }
        if case .image(let base64, _, _) = block {
            guard let data = Data(base64Encoded: base64) else { return }
            currentReplayUserMessage().appendImage(data)
            return
        }
        guard let text = block.textValue, !text.isEmpty else { return }
        currentReplayUserMessage().append(text)
    }

    private func currentReplayUserMessage() -> MessageItem {
        if let current = replayUserMessage { return current }
        let item = MessageItem(role: .user, isStreaming: true)
        replayUserMessage = item
        appendItem(item)
        return item
    }

    private func appendStreaming(role: MessageRole, block: ContentBlock) {
        // Image blocks attach to the streaming message of their role.
        if case .image(let base64, _, _) = block {
            guard let data = Data(base64Encoded: base64) else { return }
            finishReplayUserMessage()
            switch role {
            case .agent:
                if streamingAgentMessage == nil {
                    let item = MessageItem(role: .agent, isStreaming: true)
                    streamingAgentMessage = item
                    appendItem(item)
                }
                streamingAgentMessage?.appendImage(data)
            case .thought, .user:
                break
            }
            return
        }
        guard let text = block.textValue, !text.isEmpty else { return }
        finishReplayUserMessage()
        switch role {
        case .agent:
            if let streamingThought { streamingThought.finishStreaming() }
            streamingThought = nil
            if let current = streamingAgentMessage {
                current.append(text)
            } else {
                let item = MessageItem(role: .agent, isStreaming: true)
                item.append(text)
                streamingAgentMessage = item
                appendItem(item)
            }
        case .thought:
            if let streamingAgentMessage { streamingAgentMessage.finishStreaming() }
            streamingAgentMessage = nil
            if let current = streamingThought {
                current.append(text)
            } else {
                let item = MessageItem(role: .thought, isStreaming: true)
                item.append(text)
                streamingThought = item
                appendItem(item)
            }
        case .user:
            break
        }
    }

    private func finishReplayUserMessage() {
        guard let message = replayUserMessage else { return }
        replayUserMessage = nil
        // A user turn that is nothing but a harness envelope (a background-task
        // notification, system reminder, slash-command echo, …) is noise as a
        // chat bubble — the user didn't write it. Drop it instead of finishing
        // it. Only replayed turns reach here; locally-sent prompts append via a
        // separate path, so real input is never at risk.
        if Self.isHarnessEnvelope(message.fullText) {
            dropReplayItem(message)
            return
        }
        message.finishStreaming()
    }

    /// Remove a transcript item appended during (or right after) replay,
    /// targeting whichever collection `appendItem` put it in.
    private func dropReplayItem(_ item: TranscriptItem) {
        if isReplaying {
            replayBuffer.removeAll { $0 === item }
        } else {
            items.removeAll { $0 === item }
        }
    }

    private func closeStreams() {
        finishReplayUserMessage()
        streamingAgentMessage?.finishStreaming()
        streamingAgentMessage = nil
        streamingThought?.finishStreaming()
        streamingThought = nil
    }

    private func finishTurn(_ stopReason: StopReason?) {
        closeStreams()
        isTurnActive = false
        lastStopReason = stopReason
        // A question can't outlive its turn — the asking tool call is gone.
        pendingElicitation?.answer(.cancel)
        pendingElicitation = nil
        // Abnormal endings would otherwise look like the agent just chose to
        // stop talking.
        switch stopReason {
        case .maxTokens:
            appendNotice(.error, "Turn stopped: the model hit its token limit.")
        case .maxTurnRequests:
            appendNotice(.error, "Turn stopped: too many model requests in one turn.")
        case .refusal:
            appendNotice(.info, "The agent declined to continue with this request.")
        case .endTurn, .cancelled, nil:
            break
        }
        onActivityChange?()
        // A cancel means "stop", not "go on with the next thing" — queued
        // prompts stay parked as chips until the user releases them.
        if stopReason != .cancelled { flushQueue() }
    }

    private func handleUnknown(type: String, payload: JSONValue) {
        switch type {
        case "usage_update":
            usage = UsageSnapshot(
                usedTokens: payload["used"]?.intValue,
                contextSize: payload["size"]?.intValue,
                costAmount: payload["cost"]?["amount"]?.numberValue,
                costCurrency: payload["cost"]?["currency"]?.stringValue)
        case "session_info_update":
            // claude-agent-acp / opencode: the conversation's agent-side name.
            if let title = payload["title"]?.stringValue, !title.isEmpty,
                title != sessionTitle {
                sessionTitle = title
                onSessionTitleChange?()
            }
        default:
            break  // Ignore other non-spec updates.
        }
    }

    /// Single append path: wires the in-place-growth hook and pings the
    /// growth pulse so auto-follow sees every transcript change.
    private func appendItem(_ item: TranscriptItem) {
        // Suppress growth pulses while replaying — the item isn't rendered yet
        // (it's in the buffer), and endReplay sends one pulse for the batch.
        item.onMutate = { [weak self] in
            guard let self, !self.isReplaying else { return }
            self.transcriptDidGrow.send()
        }
        if isReplaying {
            replayBuffer.append(item)
        } else {
            items.append(item)
            transcriptDidGrow.send()
        }
    }

    private func appendNotice(
        _ severity: NoticeItem.Severity, _ message: String, detail: String? = nil
    ) {
        appendItem(NoticeItem(severity: severity, message: message, detail: detail))
    }

    /// Stable fragments of stderr chatter that some agent harnesses (e.g.
    /// Claude Code) print mid-turn as internal bookkeeping — not a stall or
    /// failure. Matched as substrings since IDs/paths vary. Kept in
    /// `stderrTail` for diagnostics but not surfaced as transcript errors.
    private static let benignStderrFragments = [
        "No onPostToolUseHook found for tool use ID",
    ]

    private static func isBenignAgentLog(_ line: String) -> Bool {
        benignStderrFragments.contains { line.contains($0) }
    }

    private func describe(_ error: Error) -> String {
        if case ACPError.rpc(let obj) = error { return obj.message }
        if case ACPError.transportClosed = error { return "agent process exited" }
        // Both carry a human string — surface it, not the Swift case name (a
        // notice reading "malformedMessage(...)" is what leaked to the phone).
        if case ACPError.malformedMessage(let m) = error { return m }
        if case ACPError.decodingFailed(_, let underlying) = error { return underlying }
        return String(describing: error)
    }

    // MARK: - Copy scopes (drive the macOS right-click menu)

    /// Every agent message in the turn containing `item`, joined — the full
    /// answer even when tool calls split it into several bubbles. A turn is
    /// bounded by the user messages on either side; prose only.
    public func answerText(around item: MessageItem) -> String {
        guard let idx = items.firstIndex(where: { $0 === item }) else { return item.fullText }
        func isUser(_ i: Int) -> Bool { (items[i] as? MessageItem)?.role == .user }
        var start = idx
        while start > 0, !isUser(start - 1) { start -= 1 }
        var end = idx
        while end + 1 < items.count, !isUser(end + 1) { end += 1 }
        let prose = items[start...end].compactMap { it -> String? in
            guard let m = it as? MessageItem, m.role == .agent else { return nil }
            let t = m.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return prose.isEmpty ? item.fullText : prose.joined(separator: "\n\n")
    }

    /// The whole conversation as paste-ready markdown: user + agent prose only
    /// (tool calls and reasoning omitted), each turn under a role heading.
    public func conversationMarkdown() -> String {
        items.compactMap { it -> String? in
            guard let m = it as? MessageItem else { return nil }
            let t = m.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            switch m.role {
            case .user: return "## You\n\(t)"
            case .agent: return "## Agent\n\(t)"
            case .thought: return nil
            }
        }.joined(separator: "\n\n")
    }

    // MARK: - Voice ASR biasing context

    /// The small, relevant slice of the conversation worth biasing the ASR
    /// corpus with: the TAIL of user + agent PROSE only — code fences stripped,
    /// tool calls / notices / reasoning excluded (they're separate items), and
    /// capped tight. A big raw-transcript corpus (agent output, code, tool logs)
    /// swamps Qwen and it mis-recognizes / echoes the corpus, so this stays
    /// small and on-topic. Empty until there's prose. Chronological order.
    public func voiceContext(maxChars: Int = 1200) -> String {
        var picked: [String] = []
        var total = 0
        for item in items.reversed() {
            guard let m = item as? MessageItem, m.role == .user || m.role == .agent
            else { continue }
            let prose = Self.strippingCodeFences(m.fullText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prose.isEmpty else { continue }
            picked.append(prose)
            total += prose.count
            if total >= maxChars { break }
        }
        let joined = picked.reversed().joined(separator: "\n")
        return joined.count > maxChars ? String(joined.suffix(maxChars)) : joined
    }

    private static let codeFenceRegex = try? NSRegularExpression(pattern: "```[\\s\\S]*?```")
    private static func strippingCodeFences(_ text: String) -> String {
        guard let re = codeFenceRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }
}

// MARK: - Connection bridge

/// Adapts the nonisolated ACPClientHandler callbacks onto the MainActor
/// session view model.
public final class SessionConnectionBridge: ACPClientHandler, @unchecked Sendable {
    // Only mutated at setup time from the MainActor.
    public weak var session: AgentSessionViewModel?

    public init() {}

    public func sessionUpdate(_ notification: SessionNotification) async {
        await MainActor.run { [weak session] in
            session?.handle(notification)
        }
    }

    public func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionOutcome {
        await withCheckedContinuation { continuation in
            Task { @MainActor [weak session] in
                guard let session else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                session.presentPermission(request) { outcome in
                    continuation.resume(returning: outcome)
                }
            }
        }
    }

    public func createElicitation(_ request: CreateElicitationRequest) async -> CreateElicitationResponse {
        await withCheckedContinuation { continuation in
            Task { @MainActor [weak session] in
                guard let session else {
                    continuation.resume(returning: .cancel)
                    return
                }
                session.presentElicitation(request) { response in
                    continuation.resume(returning: response)
                }
            }
        }
    }

    public func connectionDidClose(error: Error?) async {
        await MainActor.run { [weak session] in
            session?.handleConnectionDropped(error: error)
        }
    }
}
