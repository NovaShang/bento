import Foundation

// ACP content types (mirrors MCP content). Wire discriminator: `type`.

public struct ACPAnnotations: Codable, Sendable, Equatable {
    public var audience: [String]?
    public var lastModified: String?
    public var priority: Double?

    public init(audience: [String]? = nil, lastModified: String? = nil, priority: Double? = nil) {
        self.audience = audience
        self.lastModified = lastModified
        self.priority = priority
    }
}

public struct TextResourceContents: Codable, Sendable, Equatable {
    public var uri: String
    public var text: String
    public var mimeType: String?

    public init(uri: String, text: String, mimeType: String? = nil) {
        self.uri = uri
        self.text = text
        self.mimeType = mimeType
    }
}

public struct BlobResourceContents: Codable, Sendable, Equatable {
    public var uri: String
    public var blob: String
    public var mimeType: String?

    public init(uri: String, blob: String, mimeType: String? = nil) {
        self.uri = uri
        self.blob = blob
        self.mimeType = mimeType
    }
}

public enum EmbeddedResource: Codable, Sendable, Equatable {
    case text(TextResourceContents)
    case blob(BlobResourceContents)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let t = try? container.decode(TextResourceContents.self) {
            self = .text(t)
        } else {
            self = .blob(try container.decode(BlobResourceContents.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let t): try container.encode(t)
        case .blob(let b): try container.encode(b)
        }
    }
}

/// A content block in prompts, agent messages, and tool-call output.
public enum ContentBlock: Sendable, Equatable {
    case text(String, annotations: ACPAnnotations? = nil)
    case image(data: String, mimeType: String, uri: String? = nil)
    case audio(data: String, mimeType: String)
    case resourceLink(uri: String, name: String, title: String? = nil, mimeType: String? = nil)
    case resource(EmbeddedResource)
    /// Non-spec / future content type preserved verbatim.
    case unknown(type: String, payload: JSONValue)
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, annotations, data, mimeType, uri, name, title, resource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(
                try c.decode(String.self, forKey: .text),
                annotations: try c.decodeIfPresent(ACPAnnotations.self, forKey: .annotations))
        case "image":
            self = .image(
                data: try c.decode(String.self, forKey: .data),
                mimeType: try c.decode(String.self, forKey: .mimeType),
                uri: try c.decodeIfPresent(String.self, forKey: .uri))
        case "audio":
            self = .audio(
                data: try c.decode(String.self, forKey: .data),
                mimeType: try c.decode(String.self, forKey: .mimeType))
        case "resource_link":
            self = .resourceLink(
                uri: try c.decode(String.self, forKey: .uri),
                name: try c.decode(String.self, forKey: .name),
                title: try c.decodeIfPresent(String.self, forKey: .title),
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType))
        case "resource":
            self = .resource(try c.decode(EmbeddedResource.self, forKey: .resource))
        default:
            let payload = try JSONValue(from: decoder)
            self = .unknown(type: type, payload: payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let annotations):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(annotations, forKey: .annotations)
        case .image(let data, let mimeType, let uri):
            try c.encode("image", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encodeIfPresent(uri, forKey: .uri)
        case .audio(let data, let mimeType):
            try c.encode("audio", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
        case .resourceLink(let uri, let name, let title, let mimeType):
            try c.encode("resource_link", forKey: .type)
            try c.encode(uri, forKey: .uri)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(mimeType, forKey: .mimeType)
        case .resource(let resource):
            try c.encode("resource", forKey: .type)
            try c.encode(resource, forKey: .resource)
        case .unknown(_, let payload):
            try payload.encode(to: encoder)
        }
    }
}

extension ContentBlock {
    /// Plain-text projection used by transcript rendering.
    public var textValue: String? {
        switch self {
        case .text(let t, _): return t
        case .resource(.text(let r)): return r.text
        default: return nil
        }
    }
}
