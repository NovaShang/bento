import ACPKit
import ACPHostKit
import Foundation

// Transcript items are reference types so a streaming chunk only invalidates
// the row it lands in — the items array itself changes only when a new item
// appears. This is the core of keeping long transcripts smooth.

@MainActor
public class TranscriptItem: Identifiable, ObservableObject {
    public let id: String

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

    private var pendingText = ""
    private var flushScheduled = false

    public init(role: MessageRole, text: String = "", isStreaming: Bool = false) {
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        super.init()
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
    }

    public func finishStreaming() {
        flush()
        isStreaming = false
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
    }

    /// Concatenated plain-text output (terminal-style tool results).
    public var textOutput: String {
        content.compactMap { item in
            if case .content(let block) = item { return block.textValue }
            return nil
        }.joined()
    }

    public var diffs: [(path: String, oldText: String?, newText: String)] {
        content.compactMap { item in
            if case .diff(let path, let old, let new) = item { return (path, old, new) }
            return nil
        }
    }
}

/// Turn-level failure surfaced inline (agent error, transport death).
@MainActor
public final class NoticeItem: TranscriptItem {
    public enum Severity: Sendable { case info, error }

    public let severity: Severity
    public let message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
        super.init()
    }
}
