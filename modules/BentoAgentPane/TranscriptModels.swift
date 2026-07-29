import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import ACPKit
import ACPHostKit
import Combine
import Foundation

// Transcript items are reference types so a streaming chunk only invalidates
// the row it lands in — the items array itself changes only when a new item
// appears. This is the core of keeping long transcripts smooth.

@MainActor
public class TranscriptItem: Identifiable, ObservableObject {
    public let id: String

    /// Fired when this item's rendered content grows in place (streaming
    /// text, tool merge) — the transcript's auto-follow rides on it, since
    /// in-place growth never changes the item count.
    public var onMutate: (@MainActor () -> Void)?

    init(id: String = UUID().uuidString) {
        self.id = id
    }
}

public enum MessageRole: Sendable {
    case user
    case agent
    case thought
}

/// A user / agent / thought message. Text accumulates during streaming;
/// appends are coalesced (~30 ms) so markdown re-parsing doesn't run per token.
@MainActor
public final class MessageItem: TranscriptItem {
    public let role: MessageRole
    @Published public private(set) var text: String
    @Published public var isStreaming: Bool
    /// Inline images (user attachments; agent-sent image blocks).
    @Published public private(set) var images: [Data]

    private var pendingText = ""
    private var flushScheduled = false

    public init(role: MessageRole, text: String = "", isStreaming: Bool = false, images: [Data] = []) {
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.images = images
        super.init()
    }

    public func appendImage(_ data: Data) {
        images.append(data)
        onMutate?()
    }

    public func append(_ chunk: String) {
        pendingText += chunk
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            self?.flush()
        }
    }

    public func flush() {
        flushScheduled = false
        guard !pendingText.isEmpty else { return }
        text += pendingText
        pendingText = ""
        onMutate?()
    }

    public func finishStreaming() {
        flush()
        if isStreaming {
            isStreaming = false
            // The label flip ("Thinking…" → "Thought") is rendered content;
            // flush() only fires onMutate when text was pending, so without
            // this a quiet stream end left group summaries stale.
            onMutate?()
        }
    }

    /// Full text including not-yet-flushed chunks (for logic, not rendering).
    public var fullText: String { text + pendingText }
}

/// A tool call card, updated in place as tool_call_update notifications land.
@MainActor
public final class ToolCallItem: TranscriptItem {
    @Published public var title: String
    @Published public var kind: ToolKind
    @Published public var status: ToolCallStatus
    @Published public var content: [ToolCallContent]
    @Published public var locations: [ToolCallLocation]
    @Published public var rawInput: JSONValue?
    @Published public var rawOutput: JSONValue?

    public let toolCallId: String

    public init(update: ToolCallUpdate) {
        toolCallId = update.toolCallId
        title = update.title ?? update.toolCallId
        kind = update.kind ?? .other
        status = update.status ?? .pending
        content = update.content ?? []
        locations = update.locations ?? []
        rawInput = update.rawInput
        rawOutput = update.rawOutput
        super.init(id: "tool-\(update.toolCallId)")
    }

    public func merge(_ update: ToolCallUpdate) {
        if let t = update.title { title = t }
        if let k = update.kind { kind = k }
        if let s = update.status { status = s }
        if let c = update.content { content = c }
        if let l = update.locations { locations = l }
        if let input = update.rawInput { rawInput = input }
        if let output = update.rawOutput { rawOutput = output }
        onMutate?()
    }

    /// Concatenated plain-text output (terminal-style tool results).
    public var textOutput: String {
        content.compactMap { item in
            if case .content(let block) = item { return block.textValue }
            return nil
        }.joined()
    }

    /// Decoded image blocks in the tool output (Read on an image file, Bash
    /// piping image data) — rendered as thumbnails in the card.
    public var imageOutputs: [Data] {
        content.compactMap { item in
            if case .content(.image(let base64, _, _)) = item {
                return Data(base64Encoded: base64)
            }
            return nil
        }
    }

    public var diffs: [(path: String, oldText: String?, newText: String)] {
        content.compactMap { item in
            if case .diff(let path, let old, let new) = item { return (path, old, new) }
            return nil
        }
    }

    /// Embedded terminal references (client-terminal capability); we don't
    /// host agent terminals yet, so these render as a labelled placeholder.
    public var terminalIds: [String] {
        content.compactMap { item in
            if case .terminal(let id) = item { return id }
            return nil
        }
    }
}

/// A subagent — a Task/Agent tool call and the tool calls it made — folded out
/// of the linear transcript into one group. The spawning Task call is the
/// `header`; its inner calls (attributed on the wire via
/// `ToolCallUpdate.parentToolUseId`) accumulate in `children` and render in the
/// floating panel, so they never interleave with the main agent's prose. In the
/// transcript proper the whole subagent shows as a single chip.
@MainActor
public final class SubagentGroupItem: TranscriptItem {
    /// The spawning Task/Agent tool call. Its title/status/output drive the
    /// group's title, status dot, and final inline result.
    @Published public private(set) var header: ToolCallItem
    /// The subagent's own tool calls, in arrival order.
    @Published public private(set) var children: [ToolCallItem] = []

    public var parentToolCallId: String { header.toolCallId }

    private var cancellables = Set<AnyCancellable>()

    public init(header: ToolCallItem) {
        self.header = header
        super.init(id: "subagent-\(header.toolCallId)")
        adopt(header)
    }

    /// Merge an update into the spawning Task call (title firming up, final
    /// status + output when the subagent finishes).
    public func mergeHeader(_ update: ToolCallUpdate) {
        header.merge(update)
        onMutate?()
    }

    /// Record a tool call the subagent made (first sighting). Merges of that
    /// child thereafter go straight through the child's own `merge`, which
    /// pulses this group via the adopted `onMutate`.
    public func addChild(_ child: ToolCallItem) {
        adopt(child)
        children.append(child)
        onMutate?()
    }

    /// Route a child/header's in-place growth up through the group: `onMutate`
    /// drives the transcript's auto-follow, and forwarding `objectWillChange`
    /// makes a single `@ObservedObject` on the group enough to redraw the chip
    /// and panel when the header settles or a child's status flips (the group's
    /// own `@Published` only fires when the header/children references change,
    /// not on their internal mutations).
    private func adopt(_ item: ToolCallItem) {
        item.onMutate = { [weak self] in self?.onMutate?() }
        item.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Chip label — the Task's `description` argument when the agent gave one,
    /// else the tool call's own title.
    public var title: String {
        if let desc = header.rawInput?["description"]?.stringValue, !desc.isEmpty {
            return desc
        }
        return header.title
    }

    /// Rolled-up lifecycle for the status dot; tracks the spawning Task call —
    /// `completed`/`failed` once the subagent settles, `inProgress` while it
    /// works, `pending` before it starts.
    public var status: ToolCallStatus { header.status }

    public var isRunning: Bool { status == .pending || status == .inProgress }

    /// The subagent's final answer (the Task tool's textual output), shown
    /// inline on the chip once it completes; empty while still running.
    public var finalResult: String { header.textOutput }

    public var stepCount: Int { children.count }
}

extension JSONValue {
    /// Pretty-printed JSON for raw tool input/output display. A bare string
    /// value renders unquoted (command lines read better that way).
    public var prettyPrinted: String? {
        if let s = stringValue { return s }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Turn-level failure surfaced inline (agent error, transport death).
@MainActor
public final class NoticeItem: TranscriptItem {
    public enum Severity: Sendable { case info, error }

    public let severity: Severity
    public let message: String
    /// Expandable mono payload (e.g. the agent's last stderr lines).
    public let detail: String?

    public init(severity: Severity, message: String, detail: String? = nil) {
        self.severity = severity
        self.message = message
        self.detail = detail
        super.init()
    }
}
