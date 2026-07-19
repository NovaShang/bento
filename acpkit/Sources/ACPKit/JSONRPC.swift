import Foundation

// JSON-RPC 2.0 plumbing for ACP. Framing is newline-delimited JSON: one
// message per line, no header. See docs/acp-native-architecture.md.

public enum JSONRPCID: Hashable, Sendable {
    case number(Int64)
    case string(String)
}

extension JSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let n = try? container.decode(Int64.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "id must be number or string")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        }
    }
}

public struct JSONRPCErrorObject: Codable, Sendable, Equatable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// ACP-specific: agent requires authentication before this call.
    public static let authRequired = -32000
}

public enum ACPError: Error, Sendable {
    case rpc(JSONRPCErrorObject)
    case transportClosed
    case malformedMessage(String)
    case decodingFailed(method: String, underlying: String)
}

/// Classification shell for an incoming message. Typed params/results are
/// decoded from the original line data to avoid a JSONValue round-trip.
struct IncomingHeader: Decodable {
    var id: JSONRPCID?
    var method: String?
    var error: JSONRPCErrorObject?
    var hasResult: Bool

    enum CodingKeys: String, CodingKey { case id, method, error, result }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(JSONRPCID.self, forKey: .id)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        error = try c.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error)
        hasResult = c.contains(.result)
    }
}

struct ParamsEnvelope<P: Decodable>: Decodable {
    var params: P
}

struct ResultEnvelope<R: Decodable>: Decodable {
    var result: R
}

struct OutgoingRequest<P: Encodable>: Encodable {
    var jsonrpc = "2.0"
    var id: JSONRPCID
    var method: String
    var params: P?
}

struct OutgoingNotification<P: Encodable>: Encodable {
    var jsonrpc = "2.0"
    var method: String
    var params: P?
}

struct OutgoingResponse<R: Encodable>: Encodable {
    var jsonrpc = "2.0"
    var id: JSONRPCID
    var result: R
}

struct OutgoingErrorResponse: Encodable {
    var jsonrpc = "2.0"
    var id: JSONRPCID
    var error: JSONRPCErrorObject
}

/// Splits an incoming byte stream into newline-delimited frames.
/// Tolerates CRLF and skips blank lines.
public struct NDJSONLineBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
