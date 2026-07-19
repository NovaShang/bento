import Foundation

// Tool call reporting: session/update tool_call & tool_call_update, plus the
// pieces shared with permission requests.

public enum ToolKind: String, Codable, Sendable, CaseIterable {
    case read, edit, delete, move, search, execute, think, fetch
    case switchMode = "switch_mode"
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ToolKind(rawValue: raw) ?? .other
    }
}

public enum ToolCallStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ToolCallStatus(rawValue: raw) ?? .pending
    }
}

public struct ToolCallLocation: Codable, Sendable, Equatable {
    public var path: String
    public var line: Int?

    public init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }
}

/// Content attached to a tool call: regular content, a diff, or an embedded
/// terminal. Wire discriminator: `type`.
public enum ToolCallContent: Sendable, Equatable {
    case content(ContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(terminalId: String)
    case unknown(type: String, payload: JSONValue)
}

extension ToolCallContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, content, path, oldText, newText, terminalId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "content":
            self = .content(try c.decode(ContentBlock.self, forKey: .content))
        case "diff":
            self = .diff(
                path: try c.decode(String.self, forKey: .path),
                oldText: try c.decodeIfPresent(String.self, forKey: .oldText),
                newText: try c.decode(String.self, forKey: .newText))
        case "terminal":
            self = .terminal(terminalId: try c.decode(String.self, forKey: .terminalId))
        default:
            self = .unknown(type: type, payload: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .content(let block):
            try c.encode("content", forKey: .type)
            try c.encode(block, forKey: .content)
        case .diff(let path, let oldText, let newText):
            try c.encode("diff", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(oldText, forKey: .oldText)
            try c.encode(newText, forKey: .newText)
        case .terminal(let terminalId):
            try c.encode("terminal", forKey: .type)
            try c.encode(terminalId, forKey: .terminalId)
        case .unknown(_, let payload):
            try payload.encode(to: encoder)
        }
    }
}

/// Fields reported for a tool call. `tool_call` (initial) requires `title`;
/// `tool_call_update` and permission requests carry any subset.
public struct ToolCallUpdate: Codable, Sendable, Equatable {
    public var toolCallId: String
    public var title: String?
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public init(
        toolCallId: String, title: String? = nil, kind: ToolKind? = nil,
        status: ToolCallStatus? = nil, content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil, rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }
}

public struct PlanEntry: Codable, Sendable, Equatable {
    public enum Priority: String, Codable, Sendable {
        case high, medium, low
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Priority(rawValue: raw) ?? .medium
        }
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .pending
        }
    }

    public var content: String
    public var priority: Priority
    public var status: Status

    public init(content: String, priority: Priority = .medium, status: Status = .pending) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

public struct PermissionOption: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .rejectOnce
        }
    }

    public var optionId: String
    public var name: String
    public var kind: Kind

    public init(optionId: String, name: String, kind: Kind) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }
}
