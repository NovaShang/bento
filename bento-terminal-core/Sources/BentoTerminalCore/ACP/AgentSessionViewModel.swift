import ACPKit
import ACPHostKit
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

public struct UsageSnapshot: Sendable, Equatable {
    public var usedTokens: Int?
    public var contextSize: Int?
    public var costAmount: Double?
    public var costCurrency: String?
}

/// A prompt written while a turn was still running; sent automatically when
/// the turn finishes (unless the user cancelled).
public struct QueuedMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String

    init(text: String) {
        self.id = UUID()
        self.text = text
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
        case failed(String)
        case ended
    }

    public let id = UUID()
    public let preset: ACPAgentPreset
    public let cwd: String

    @Published public private(set) var items: [TranscriptItem] = []
    @Published public private(set) var plan: [PlanEntry] = []
    @Published public private(set) var phase: Phase = .starting
    @Published public private(set) var isTurnActive = false
    @Published public private(set) var pendingPermission: PermissionPrompt?
    @Published public private(set) var modes: SessionModeState?
    @Published public private(set) var models: SessionModelState?
    @Published public private(set) var availableCommands: [AvailableCommand] = []
    @Published public private(set) var usage: UsageSnapshot?
    @Published public private(set) var queuedMessages: [QueuedMessage] = []
    @Published public private(set) var lastStopReason: StopReason?
    /// Set by the workspace when a turn finishes while the session is not
    /// focused; cleared when the user views the session.
    @Published public var hasUnseenCompletion = false
    /// Composer draft lives on the session so voice (and future sources)
    /// can inject text exactly like the old pty insert did.
    @Published public var composerDraft = ""

    public private(set) var sessionId: String?
    /// Daemon-side instance id for persistent agents (attach/reattach).
    public private(set) var agentID: String?
    @Published public var title: String

    /// Workspace hook, fired on any activity-state-relevant change.
    var onActivityChange: (@MainActor () -> Void)?

    private var connection: ACPConnection?
    private var hostTransport: AcpHostTransport?
    private var toolItems: [String: ToolCallItem] = [:]
    private var streamingAgentMessage: MessageItem?
    private var streamingThought: MessageItem?
    private var replayUserMessage: MessageItem?
    /// Attached while a detached-started turn was still running; history
    /// backfills (session/load) once that turn completes.
    private var attachedMidTurn = false

    public init(preset: ACPAgentPreset, cwd: String) {
        self.preset = preset
        self.cwd = cwd
        self.title = (cwd as NSString).lastPathComponent
    }

    public var activityState: SessionActivityState {
        if pendingPermission != nil { return .awaiting }
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
            let initResp = try await connection.initialize()
            guard initResp.protocolVersion >= 1 else {
                throw ACPError.malformedMessage("unsupported protocol \(initResp.protocolVersion)")
            }
            if let resumeSessionId, initResp.agentCapabilities?.loadSession == true {
                let resp = try await connection.loadSession(sessionId: resumeSessionId, cwd: cwd)
                sessionId = resumeSessionId
                modes = resp.modes
                models = resp.models
            } else {
                let resp = try await connection.newSession(cwd: cwd)
                sessionId = resp.sessionId
                modes = resp.modes
                models = resp.models
            }
            closeStreams()
            phase = .ready
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
            let initResp = try await connection.initialize()
            guard initResp.protocolVersion >= 1 else {
                throw ACPError.malformedMessage("unsupported protocol \(initResp.protocolVersion)")
            }
            if let known = launch.attachInfo?.acpSessionID, !known.isEmpty {
                sessionId = known
            } else if let resumeSessionId, !resumeSessionId.isEmpty,
                      initResp.agentCapabilities?.loadSession == true {
                sessionId = resumeSessionId
            }
            if launch.attachInfo?.turnActive == true {
                attachedMidTurn = true
                isTurnActive = true
                phase = .ready
                appendNotice(.info, "Attached mid-turn — full history loads when this turn completes.")
            } else if let sid = sessionId {
                let resp = try await connection.loadSession(sessionId: sid, cwd: cwd)
                modes = resp.modes
                models = resp.models
                closeStreams()
                phase = .ready
            } else {
                let resp = try await connection.newSession(cwd: cwd)
                sessionId = resp.sessionId
                modes = resp.modes
                models = resp.models
                phase = .ready
            }
        } catch {
            phase = .failed(describe(error))
            appendNotice(.error, "Failed to attach \(preset.name): \(describe(error))")
        }
        onActivityChange?()
    }

    private func bindTransportEvents() {
        hostTransport?.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleHostEvent(event)
            }
        }
    }

    private func handleHostEvent(_ event: AcpHostEvent) {
        switch event {
        case .agentExited:
            break  // The transport finishes `incoming`; connectionDidClose reports it.
        case .detachedByAnotherClient:
            appendNotice(.info, "Session opened on another device — detached here.")
            shutdown()
        case .turnFinishedWhileDetached(let stopReason):
            isTurnActive = false
            lastStopReason = StopReason(rawValue: stopReason) ?? .endTurn
            if attachedMidTurn {
                attachedMidTurn = false
                Task { await self.refreshFromHistory() }
            }
            onActivityChange?()
        case .stderrLine:
            break
        case .stateChanged:
            break  // Workspace-structure sync is the store's concern.
        }
    }

    /// Rebuild the transcript from the agent's own conversation storage.
    private func refreshFromHistory() async {
        guard let connection, let sid = sessionId else { return }
        resetTranscript()
        do {
            let resp = try await connection.loadSession(sessionId: sid, cwd: cwd)
            modes = resp.modes
            models = resp.models
            closeStreams()
        } catch {
            appendNotice(.error, "History reload failed: \(describe(error))")
        }
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
        if phase == .ready || phase == .starting { phase = .ended }
    }

    // MARK: - User actions

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .ready, let connection, let sessionId else { return }
        if isTurnActive {
            queuedMessages.append(QueuedMessage(text: trimmed))
            return
        }
        let item = MessageItem(role: .user, text: trimmed)
        items.append(item)
        isTurnActive = true
        lastStopReason = nil
        onActivityChange?()
        Task { [weak self] in
            do {
                let resp = try await connection.prompt(sessionId: sessionId, blocks: [.text(trimmed)])
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

    public func cancelTurn() {
        guard isTurnActive, let connection, let sessionId else { return }
        // Spec: a cancelling client must answer pending permission requests
        // with cancelled.
        pendingPermission?.answer(.cancelled)
        pendingPermission = nil
        Task { try? await connection.cancel(sessionId: sessionId) }
    }

    public func respondPermission(_ outcome: RequestPermissionOutcome) {
        pendingPermission?.answer(outcome)
        pendingPermission = nil
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
        send(message.text)
    }

    private func flushQueue() {
        guard !isTurnActive, phase == .ready, !queuedMessages.isEmpty else { return }
        let next = queuedMessages.removeFirst()
        send(next.text)
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
                items.append(item)
            }
        case .toolCallUpdate(let update):
            if let existing = toolItems[update.toolCallId] {
                existing.merge(update)
            } else {
                let item = ToolCallItem(update: update)
                toolItems[update.toolCallId] = item
                items.append(item)
            }
        case .plan(let entries):
            plan = entries
        case .availableCommandsUpdate(let commands):
            availableCommands = commands
        case .currentModeUpdate(let modeId):
            modes?.currentModeId = modeId
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

    func handleConnectionClosed(error: Error?) {
        pendingPermission?.answer(.cancelled)
        pendingPermission = nil
        closeStreams()
        if isTurnActive { isTurnActive = false }
        if phase == .ready || phase == .starting {
            phase = .ended
            appendNotice(.error, "Agent exited\(error.map { ": \(describe($0))" } ?? "")")
        }
        onActivityChange?()
    }

    // MARK: - Internals

    private func handleUserChunk(_ block: ContentBlock) {
        // Locally-sent prompts already appear in the transcript; user chunks
        // only matter when replaying history via session/load.
        guard !isTurnActive else { return }
        guard let text = block.textValue, !text.isEmpty else { return }
        if let current = replayUserMessage {
            current.append(text)
        } else {
            let item = MessageItem(role: .user, isStreaming: true)
            item.append(text)
            replayUserMessage = item
            items.append(item)
        }
    }

    private func appendStreaming(role: MessageRole, block: ContentBlock) {
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
                items.append(item)
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
                items.append(item)
            }
        case .user:
            break
        }
    }

    private func finishReplayUserMessage() {
        replayUserMessage?.finishStreaming()
        replayUserMessage = nil
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
        default:
            break  // Ignore other non-spec updates.
        }
    }

    private func appendNotice(_ severity: NoticeItem.Severity, _ message: String) {
        items.append(NoticeItem(severity: severity, message: message))
    }

    private func describe(_ error: Error) -> String {
        if case ACPError.rpc(let obj) = error { return obj.message }
        if case ACPError.transportClosed = error { return "agent process exited" }
        return String(describing: error)
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

    public func connectionDidClose(error: Error?) async {
        await MainActor.run { [weak session] in
            session?.handleConnectionClosed(error: error)
        }
    }
}
