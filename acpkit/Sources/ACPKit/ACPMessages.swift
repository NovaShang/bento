import Foundation

// Request/response payloads for the agent-side methods, and the
// session/update notification. Field shapes follow ACP protocolVersion 1
// (verified against @zed-industries/agent-client-protocol 0.4.5).

public enum ACPMethod {
    // Client → agent
    public static let initialize = "initialize"
    public static let authenticate = "authenticate"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    public static let sessionSetMode = "session/set_mode"
    public static let sessionSetModel = "session/set_model"
    // Agent → client
    public static let sessionUpdate = "session/update"
    public static let sessionRequestPermission = "session/request_permission"
    public static let fsReadTextFile = "fs/read_text_file"
    public static let fsWriteTextFile = "fs/write_text_file"
    public static let terminalCreate = "terminal/create"
    public static let terminalOutput = "terminal/output"
    public static let terminalRelease = "terminal/release"
    public static let terminalWaitForExit = "terminal/wait_for_exit"
    public static let terminalKill = "terminal/kill"
}

public let acpProtocolVersion = 1

// MARK: - Capabilities

public struct FileSystemCapability: Codable, Sendable, Equatable {
    public var readTextFile: Bool?
    public var writeTextFile: Bool?

    public init(readTextFile: Bool? = nil, writeTextFile: Bool? = nil) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
    }
}

public struct ClientCapabilities: Codable, Sendable, Equatable {
    public var fs: FileSystemCapability?
    public var terminal: Bool?

    public init(fs: FileSystemCapability? = nil, terminal: Bool? = nil) {
        self.fs = fs
        self.terminal = terminal
    }
}

public struct PromptCapabilities: Codable, Sendable, Equatable {
    public var image: Bool?
    public var audio: Bool?
    public var embeddedContext: Bool?

    public init(image: Bool? = nil, audio: Bool? = nil, embeddedContext: Bool? = nil) {
        self.image = image
        self.audio = audio
        self.embeddedContext = embeddedContext
    }
}

public struct McpCapabilities: Codable, Sendable, Equatable {
    public var http: Bool?
    public var sse: Bool?

    public init(http: Bool? = nil, sse: Bool? = nil) {
        self.http = http
        self.sse = sse
    }
}

public struct AgentCapabilities: Codable, Sendable, Equatable {
    public var loadSession: Bool?
    public var promptCapabilities: PromptCapabilities?
    public var mcpCapabilities: McpCapabilities?

    public init(
        loadSession: Bool? = nil, promptCapabilities: PromptCapabilities? = nil,
        mcpCapabilities: McpCapabilities? = nil
    ) {
        self.loadSession = loadSession
        self.promptCapabilities = promptCapabilities
        self.mcpCapabilities = mcpCapabilities
    }
}

public struct AuthMethodInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

// MARK: - Initialize / authenticate

public struct InitializeRequest: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var clientCapabilities: ClientCapabilities?

    public init(protocolVersion: Int = acpProtocolVersion, clientCapabilities: ClientCapabilities? = nil) {
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
    }
}

public struct AgentInfo: Codable, Sendable, Equatable {
    public var name: String?
    public var version: String?
}

public struct InitializeResponse: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var agentCapabilities: AgentCapabilities?
    public var authMethods: [AuthMethodInfo]?
    /// Non-spec but sent by opencode; useful for display.
    public var agentInfo: AgentInfo?
}

public struct AuthenticateRequest: Codable, Sendable, Equatable {
    public var methodId: String

    public init(methodId: String) { self.methodId = methodId }
}

// MARK: - MCP server descriptors (passed through to session/new)

public struct EnvVariable: Codable, Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct HTTPHeader: Codable, Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum McpServer: Codable, Sendable, Equatable {
    case stdio(name: String, command: String, args: [String], env: [EnvVariable])
    case http(name: String, url: String, headers: [HTTPHeader])
    case sse(name: String, url: String, headers: [HTTPHeader])

    private enum CodingKeys: String, CodingKey { case type, name, command, args, env, url, headers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type)
        switch type {
        case "http":
            self = .http(
                name: try c.decode(String.self, forKey: .name),
                url: try c.decode(String.self, forKey: .url),
                headers: try c.decodeIfPresent([HTTPHeader].self, forKey: .headers) ?? [])
        case "sse":
            self = .sse(
                name: try c.decode(String.self, forKey: .name),
                url: try c.decode(String.self, forKey: .url),
                headers: try c.decodeIfPresent([HTTPHeader].self, forKey: .headers) ?? [])
        default:
            // stdio has no `type` discriminator in v1.
            self = .stdio(
                name: try c.decode(String.self, forKey: .name),
                command: try c.decode(String.self, forKey: .command),
                args: try c.decodeIfPresent([String].self, forKey: .args) ?? [],
                env: try c.decodeIfPresent([EnvVariable].self, forKey: .env) ?? [])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stdio(let name, let command, let args, let env):
            try c.encode(name, forKey: .name)
            try c.encode(command, forKey: .command)
            try c.encode(args, forKey: .args)
            try c.encode(env, forKey: .env)
        case .http(let name, let url, let headers):
            try c.encode("http", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(url, forKey: .url)
            try c.encode(headers, forKey: .headers)
        case .sse(let name, let url, let headers):
            try c.encode("sse", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(url, forKey: .url)
            try c.encode(headers, forKey: .headers)
        }
    }
}

// MARK: - Sessions

public struct SessionModeInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
}

public struct SessionModeState: Codable, Sendable, Equatable {
    public var currentModeId: String
    public var availableModes: [SessionModeInfo]
}

public struct ModelInfo: Codable, Sendable, Equatable {
    public var modelId: String
    public var name: String
    public var description: String?
}

public struct SessionModelState: Codable, Sendable, Equatable {
    public var currentModelId: String
    public var availableModels: [ModelInfo]
}

public struct NewSessionRequest: Codable, Sendable, Equatable {
    public var cwd: String
    public var mcpServers: [McpServer]

    public init(cwd: String, mcpServers: [McpServer] = []) {
        self.cwd = cwd
        self.mcpServers = mcpServers
    }
}

public struct NewSessionResponse: Codable, Sendable, Equatable {
    public var sessionId: String
    public var modes: SessionModeState?
    public var models: SessionModelState?
}

public struct LoadSessionRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var cwd: String
    public var mcpServers: [McpServer]

    public init(sessionId: String, cwd: String, mcpServers: [McpServer] = []) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers
    }
}

public struct LoadSessionResponse: Codable, Sendable, Equatable {
    public var modes: SessionModeState?
    public var models: SessionModelState?
}

public struct SetSessionModeRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var modeId: String

    public init(sessionId: String, modeId: String) {
        self.sessionId = sessionId
        self.modeId = modeId
    }
}

public struct SetSessionModelRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var modelId: String

    public init(sessionId: String, modelId: String) {
        self.sessionId = sessionId
        self.modelId = modelId
    }
}

public struct EmptyResponse: Codable, Sendable, Equatable {
    public init() {}
}

// MARK: - Prompt turn

public struct PromptRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var prompt: [ContentBlock]

    public init(sessionId: String, prompt: [ContentBlock]) {
        self.sessionId = sessionId
        self.prompt = prompt
    }
}

public enum StopReason: String, Codable, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StopReason(rawValue: raw) ?? .endTurn
    }
}

public struct PromptResponse: Codable, Sendable, Equatable {
    public var stopReason: StopReason
}

public struct CancelNotification: Codable, Sendable, Equatable {
    public var sessionId: String

    public init(sessionId: String) { self.sessionId = sessionId }
}

// MARK: - session/update

public struct AvailableCommand: Codable, Sendable, Equatable {
    public struct Input: Codable, Sendable, Equatable {
        public var hint: String?
    }

    public var name: String
    public var description: String
    public var input: Input?
}

public enum SessionUpdate: Sendable, Equatable {
    case userMessageChunk(ContentBlock)
    case agentMessageChunk(ContentBlock)
    case agentThoughtChunk(ContentBlock)
    case toolCall(ToolCallUpdate)
    case toolCallUpdate(ToolCallUpdate)
    case plan([PlanEntry])
    case availableCommandsUpdate([AvailableCommand])
    case currentModeUpdate(currentModeId: String)
    /// Anything not in the v1 spec (opencode: usage_update, session_info_update…).
    case unknown(type: String, payload: JSONValue)
}

extension SessionUpdate: Codable {
    private enum CodingKeys: String, CodingKey {
        case sessionUpdate, content, entries, availableCommands, currentModeId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .sessionUpdate)
        switch type {
        case "user_message_chunk":
            self = .userMessageChunk(try c.decode(ContentBlock.self, forKey: .content))
        case "agent_message_chunk":
            self = .agentMessageChunk(try c.decode(ContentBlock.self, forKey: .content))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try c.decode(ContentBlock.self, forKey: .content))
        case "tool_call":
            self = .toolCall(try ToolCallUpdate(from: decoder))
        case "tool_call_update":
            self = .toolCallUpdate(try ToolCallUpdate(from: decoder))
        case "plan":
            self = .plan(try c.decode([PlanEntry].self, forKey: .entries))
        case "available_commands_update":
            self = .availableCommandsUpdate(
                try c.decode([AvailableCommand].self, forKey: .availableCommands))
        case "current_mode_update":
            self = .currentModeUpdate(currentModeId: try c.decode(String.self, forKey: .currentModeId))
        default:
            self = .unknown(type: type, payload: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userMessageChunk(let block):
            try c.encode("user_message_chunk", forKey: .sessionUpdate)
            try c.encode(block, forKey: .content)
        case .agentMessageChunk(let block):
            try c.encode("agent_message_chunk", forKey: .sessionUpdate)
            try c.encode(block, forKey: .content)
        case .agentThoughtChunk(let block):
            try c.encode("agent_thought_chunk", forKey: .sessionUpdate)
            try c.encode(block, forKey: .content)
        case .toolCall(let call):
            try call.encode(to: encoder)
            try c.encode("tool_call", forKey: .sessionUpdate)
        case .toolCallUpdate(let call):
            try call.encode(to: encoder)
            try c.encode("tool_call_update", forKey: .sessionUpdate)
        case .plan(let entries):
            try c.encode("plan", forKey: .sessionUpdate)
            try c.encode(entries, forKey: .entries)
        case .availableCommandsUpdate(let commands):
            try c.encode("available_commands_update", forKey: .sessionUpdate)
            try c.encode(commands, forKey: .availableCommands)
        case .currentModeUpdate(let modeId):
            try c.encode("current_mode_update", forKey: .sessionUpdate)
            try c.encode(modeId, forKey: .currentModeId)
        case .unknown(_, let payload):
            try payload.encode(to: encoder)
        }
    }
}

public struct SessionNotification: Codable, Sendable, Equatable {
    public var sessionId: String
    public var update: SessionUpdate

    public init(sessionId: String, update: SessionUpdate) {
        self.sessionId = sessionId
        self.update = update
    }
}

// MARK: - Permission

public struct RequestPermissionRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var toolCall: ToolCallUpdate
    public var options: [PermissionOption]

    public init(sessionId: String, toolCall: ToolCallUpdate, options: [PermissionOption]) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
    }
}

public enum RequestPermissionOutcome: Sendable, Equatable {
    case selected(optionId: String)
    case cancelled
}

public struct RequestPermissionResponse: Codable, Sendable, Equatable {
    public var outcome: RequestPermissionOutcome

    public init(outcome: RequestPermissionOutcome) { self.outcome = outcome }
}

extension RequestPermissionOutcome: Codable {
    private enum CodingKeys: String, CodingKey { case outcome, optionId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .outcome) {
        case "selected":
            self = .selected(optionId: try c.decode(String.self, forKey: .optionId))
        default:
            self = .cancelled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selected(let optionId):
            try c.encode("selected", forKey: .outcome)
            try c.encode(optionId, forKey: .optionId)
        case .cancelled:
            try c.encode("cancelled", forKey: .outcome)
        }
    }
}

// MARK: - File system (client-side methods)

public struct ReadTextFileRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var path: String
    public var line: Int?
    public var limit: Int?
}

public struct ReadTextFileResponse: Codable, Sendable, Equatable {
    public var content: String

    public init(content: String) { self.content = content }
}

public struct WriteTextFileRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var path: String
    public var content: String
}

// MARK: - Terminal (client-side methods; optional capability)

public struct CreateTerminalRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var command: String
    public var args: [String]?
    public var cwd: String?
    public var env: [EnvVariable]?
    public var outputByteLimit: Int?
}

public struct CreateTerminalResponse: Codable, Sendable, Equatable {
    public var terminalId: String

    public init(terminalId: String) { self.terminalId = terminalId }
}

public struct TerminalIDRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var terminalId: String
}

public struct TerminalExitStatus: Codable, Sendable, Equatable {
    public var exitCode: Int?
    public var signal: String?

    public init(exitCode: Int? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

public struct TerminalOutputResponse: Codable, Sendable, Equatable {
    public var output: String
    public var truncated: Bool
    public var exitStatus: TerminalExitStatus?

    public init(output: String, truncated: Bool = false, exitStatus: TerminalExitStatus? = nil) {
        self.output = output
        self.truncated = truncated
        self.exitStatus = exitStatus
    }
}

public struct WaitForTerminalExitResponse: Codable, Sendable, Equatable {
    public var exitCode: Int?
    public var signal: String?

    public init(exitCode: Int? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}
