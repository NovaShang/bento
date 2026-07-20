import Foundation

// Elicitation — the agent asks the user structured questions through the
// client (`elicitation/create`). UNSTABLE ACP extension (schema 1.19+); the
// live consumer is claude-agent-acp 0.60+, which maps Claude Code's
// AskUserQuestion onto a form-mode elicitation and DISABLES that tool
// entirely for clients that don't advertise `elicitation.form`.

// MARK: - Capability

/// `{}` for a mode means "supported" — mirrors the SDK's shape where the
/// capability objects are empty-but-present.
public struct ElicitationCapability: Codable, Sendable, Equatable {
    public struct Form: Codable, Sendable, Equatable {
        public init() {}
    }
    public struct Url: Codable, Sendable, Equatable {
        public init() {}
    }

    public var form: Form?
    public var url: Url?

    public init(form: Form? = nil, url: Url? = nil) {
        self.form = form
        self.url = url
    }
}

// MARK: - Request / response

public struct CreateElicitationRequest: Codable, Sendable, Equatable {
    /// "form" (JSON-Schema fields) or "url" (browser hand-off); unknown modes
    /// pass through for forward compatibility.
    public var mode: String
    public var sessionId: String?
    /// The tool call this elicitation belongs to (AskUserQuestion's toolUseID).
    public var toolCallId: String?
    /// Human-readable prompt; for a single-question form this IS the question.
    public var message: String
    /// Form mode: JSON Schema with primitive-typed properties. Kept raw —
    /// `ElicitationForm` interprets it leniently.
    public var requestedSchema: JSONValue?
    /// Url mode.
    public var url: String?
    public var elicitationId: String?
}

public struct CreateElicitationResponse: Codable, Sendable, Equatable {
    /// "accept" | "decline" | "cancel".
    public var action: String
    /// Accepted content keyed by schema property (string / number / bool /
    /// array-of-strings values).
    public var content: [String: JSONValue]?

    public init(action: String, content: [String: JSONValue]? = nil) {
        self.action = action
        self.content = content
    }

    public static let decline = CreateElicitationResponse(action: "decline")
    public static let cancel = CreateElicitationResponse(action: "cancel")
    public static func accept(_ content: [String: JSONValue]) -> CreateElicitationResponse {
        CreateElicitationResponse(action: "accept", content: content)
    }
}

// MARK: - Parsed form

/// Lenient interpretation of a form-mode `requestedSchema` into ordered,
/// renderable fields. Unknown shapes degrade to free text rather than
/// failing the whole form.
public struct ElicitationForm: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        /// The enum `const` — what an accepted answer carries.
        public var value: String
        public var title: String
        public var detail: String?
        /// AskUserQuestion option preview (mockups/code comparisons),
        /// forwarded under `_meta._claude/askUserQuestionOption`.
        public var preview: String?
    }

    public enum FieldKind: Sendable, Equatable {
        case select([Option])
        case multiSelect([Option])
        case text
        case number
        case boolean
    }

    public struct Field: Sendable, Equatable {
        public var key: String
        public var title: String?
        public var detail: String?
        public var kind: FieldKind

        /// AskUserQuestion's per-question free-text companion
        /// (`question_<n>_custom`) — rendered as the "Other" affordance of
        /// the field it belongs to.
        public var isCustomCompanion: Bool { key.hasSuffix("_custom") }
    }

    public var fields: [Field]

    public init?(requestedSchema: JSONValue?) {
        guard let properties = requestedSchema?["properties"]?.objectValue, !properties.isEmpty
        else { return nil }
        // Dictionary decoding lost the schema's key order; natural sort keeps
        // question_<n> / question_<n>_custom pairs adjacent and in sequence.
        let keys = properties.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var fields: [Field] = []
        for key in keys {
            guard let prop = properties[key]?.objectValue else { continue }
            fields.append(Self.field(key: key, prop: prop))
        }
        guard !fields.isEmpty else { return nil }
        self.fields = fields
    }

    private static func field(key: String, prop: [String: JSONValue]) -> Field {
        let title = prop["title"]?.stringValue
        let detail = prop["description"]?.stringValue
        let type = prop["type"]?.stringValue

        if let options = enumOptions(in: prop) {
            return Field(key: key, title: title, detail: detail, kind: .select(options))
        }
        if type == "array", let items = prop["items"]?.objectValue,
            let options = enumOptions(in: items) {
            return Field(key: key, title: title, detail: detail, kind: .multiSelect(options))
        }
        switch type {
        case "boolean":
            return Field(key: key, title: title, detail: detail, kind: .boolean)
        case "number", "integer":
            return Field(key: key, title: title, detail: detail, kind: .number)
        default:
            return Field(key: key, title: title, detail: detail, kind: .text)
        }
    }

    /// `oneOf` / `anyOf` option lists and plain string `enum`s.
    private static func enumOptions(in prop: [String: JSONValue]) -> [Option]? {
        let list = prop["oneOf"]?.arrayValue ?? prop["anyOf"]?.arrayValue ?? prop["enum"]?.arrayValue
        guard let list, !list.isEmpty else { return nil }
        let options = list.compactMap { entry -> Option? in
            if let plain = entry.stringValue {
                return Option(value: plain, title: plain, detail: nil, preview: nil)
            }
            guard let object = entry.objectValue, let value = object["const"]?.stringValue else {
                return nil
            }
            return Option(
                value: value,
                title: object["title"]?.stringValue ?? value,
                detail: object["description"]?.stringValue,
                preview: object["_meta"]?["_claude/askUserQuestionOption"]?["preview"]?.stringValue)
        }
        return options.isEmpty ? nil : options
    }
}
