import Foundation

/// Handles requests and notifications the agent sends to the client.
/// `sessionUpdate` is awaited serially so chunk ordering is preserved;
/// implementations should return quickly. Requests (permission, fs, terminal)
/// are dispatched on detached tasks so a pending permission prompt never
/// blocks the update stream.
public protocol ACPClientHandler: Sendable {
    func sessionUpdate(_ notification: SessionNotification) async

    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionOutcome

    func readTextFile(_ request: ReadTextFileRequest) async throws -> ReadTextFileResponse
    func writeTextFile(_ request: WriteTextFileRequest) async throws

    func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse
    func terminalOutput(_ request: TerminalIDRequest) async throws -> TerminalOutputResponse
    func releaseTerminal(_ request: TerminalIDRequest) async throws
    func waitForTerminalExit(_ request: TerminalIDRequest) async throws -> WaitForTerminalExitResponse
    func killTerminal(_ request: TerminalIDRequest) async throws

    /// Elicitation (UNSTABLE extension): the agent asks the user structured
    /// questions. Only reached when the client advertised the capability.
    func createElicitation(_ request: CreateElicitationRequest) async -> CreateElicitationResponse

    /// Non-spec request/notification (`_`-prefixed or agent-specific).
    func extMethod(method: String, params: JSONValue?) async throws -> JSONValue
    func extNotification(method: String, params: JSONValue?) async

    /// The transport ended (agent exited or channel dropped).
    func connectionDidClose(error: Error?) async
}

/// Defaults: everything optional is unsupported.
extension ACPClientHandler {
    public func readTextFile(_ request: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        throw ACPError.rpc(.init(code: JSONRPCErrorObject.methodNotFound, message: "fs not supported"))
    }
    public func writeTextFile(_ request: WriteTextFileRequest) async throws {
        throw ACPError.rpc(.init(code: JSONRPCErrorObject.methodNotFound, message: "fs not supported"))
    }
    public func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        throw ACPError.rpc(.init(code: JSONRPCErrorObject.methodNotFound, message: "terminal not supported"))
    }
    public func terminalOutput(_ request: TerminalIDRequest) async throws -> TerminalOutputResponse {
        throw ACPError.rpc(.init(code: JSONRPCErrorObject.methodNotFound, message: "terminal not supported"))
    }
    public func releaseTerminal(_ request: TerminalIDRequest) async throws {
        throw ACPError.rpc(.init(code: JSONRPCErrorObject.methodNotFound, message: "terminal not supported"))
    }
    public func waitForTerminalExit(_ request: TerminalIDRequest) async throws -> WaitForTerminalExitResponse {
        throw ACPError.rpc(.init(code: JSONRPCErrorObject.methodNotFound, message: "terminal not supported"))
    }
    public func killTerminal(_ request: TerminalIDRequest) async throws {
        throw ACPError.rpc(.init(code: JSONRPCErrorObject.methodNotFound, message: "terminal not supported"))
    }
    public func createElicitation(_ request: CreateElicitationRequest) async -> CreateElicitationResponse {
        .cancel
    }
    public func extMethod(method: String, params: JSONValue?) async throws -> JSONValue {
        throw ACPError.rpc(.init(code: JSONRPCErrorObject.methodNotFound, message: "unknown method \(method)"))
    }
    public func extNotification(method: String, params: JSONValue?) async {}
    public func connectionDidClose(error: Error?) async {}
}

/// One ACP connection: request/response correlation plus dispatch of incoming
/// agent requests to a client handler. Owns the transport's read loop.
public actor ACPConnection {
    private let transport: any ACPTransport
    private let handler: any ACPClientHandler
    private var pending: [JSONRPCID: CheckedContinuation<Data, Error>] = [:]
    private var nextID: Int64 = 0
    private var readTask: Task<Void, Never>?
    private var closedError: Error?
    private var isClosed = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Diagnostic hook: raw inbound/outbound lines.
    public var onTrace: (@Sendable (_ outbound: Bool, _ line: Data) -> Void)?

    public init(transport: any ACPTransport, handler: any ACPClientHandler) {
        self.transport = transport
        self.handler = handler
    }

    public func setTrace(_ trace: (@Sendable (Bool, Data) -> Void)?) {
        onTrace = trace
    }

    public func start() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            guard let self else { return }
            var lineBuffer = NDJSONLineBuffer()
            do {
                for try await chunk in self.transport.incoming {
                    for line in lineBuffer.append(chunk) {
                        await self.handleLine(line)
                    }
                }
                await self.finish(error: nil)
            } catch {
                await self.finish(error: error)
            }
        }
    }

    public func close() async {
        await finish(error: nil)
    }

    // MARK: - Outbound

    public func request<P: Encodable, R: Decodable>(
        _ method: String, _ params: P?
    ) async throws -> R {
        if let closedError { throw closedError }
        if isClosed { throw ACPError.transportClosed }
        nextID += 1
        let id = JSONRPCID.number(nextID)
        let payload = try encoder.encode(OutgoingRequest(id: id, method: method, params: params))
        let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pending[id] = cont
            Task {
                do {
                    try await self.sendLine(payload)
                } catch {
                    self.failPending(id: id, error: error)
                }
            }
        }
        do {
            return try decoder.decode(ResultEnvelope<R>.self, from: data).result
        } catch {
            throw ACPError.decodingFailed(method: method, underlying: String(describing: error))
        }
    }

    public func notify<P: Encodable>(_ method: String, _ params: P?) async throws {
        let payload = try encoder.encode(OutgoingNotification(method: method, params: params))
        try await sendLine(payload)
    }

    private func sendLine(_ payload: Data) async throws {
        var line = payload
        line.append(0x0A)
        onTrace?(true, payload)
        try await transport.send(line)
    }

    private func failPending(id: JSONRPCID, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    // MARK: - Inbound

    private func handleLine(_ line: Data) async {
        onTrace?(false, line)
        guard let header = try? decoder.decode(IncomingHeader.self, from: line) else {
            return  // Not JSON-RPC; ignore (agents sometimes log to stdout).
        }
        if let method = header.method {
            if let id = header.id {
                // Agent → client request; never block the read loop.
                Task { await self.handleIncomingRequest(id: id, method: method, line: line) }
            } else {
                await handleIncomingNotification(method: method, line: line)
            }
        } else if let id = header.id {
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let error = header.error {
                cont.resume(throwing: ACPError.rpc(error))
            } else {
                cont.resume(returning: line)
            }
        }
    }

    private func handleIncomingNotification(method: String, line: Data) async {
        switch method {
        case ACPMethod.sessionUpdate:
            guard let envelope = try? decoder.decode(ParamsEnvelope<SessionNotification>.self, from: line)
            else { return }
            await handler.sessionUpdate(envelope.params)
        default:
            let params = try? decoder.decode(ParamsEnvelope<JSONValue>.self, from: line).params
            await handler.extNotification(method: method, params: params)
        }
    }

    private func handleIncomingRequest(id: JSONRPCID, method: String, line: Data) async {
        do {
            switch method {
            case ACPMethod.sessionRequestPermission:
                let req = try decodeParams(RequestPermissionRequest.self, from: line, method: method)
                let outcome = await handler.requestPermission(req)
                await respond(id: id, result: RequestPermissionResponse(outcome: outcome))
            case ACPMethod.fsReadTextFile:
                let req = try decodeParams(ReadTextFileRequest.self, from: line, method: method)
                await respond(id: id, result: try await handler.readTextFile(req))
            case ACPMethod.fsWriteTextFile:
                let req = try decodeParams(WriteTextFileRequest.self, from: line, method: method)
                try await handler.writeTextFile(req)
                await respond(id: id, result: EmptyResponse())
            case ACPMethod.terminalCreate:
                let req = try decodeParams(CreateTerminalRequest.self, from: line, method: method)
                await respond(id: id, result: try await handler.createTerminal(req))
            case ACPMethod.terminalOutput:
                let req = try decodeParams(TerminalIDRequest.self, from: line, method: method)
                await respond(id: id, result: try await handler.terminalOutput(req))
            case ACPMethod.terminalRelease:
                let req = try decodeParams(TerminalIDRequest.self, from: line, method: method)
                try await handler.releaseTerminal(req)
                await respond(id: id, result: EmptyResponse())
            case ACPMethod.terminalWaitForExit:
                let req = try decodeParams(TerminalIDRequest.self, from: line, method: method)
                await respond(id: id, result: try await handler.waitForTerminalExit(req))
            case ACPMethod.terminalKill:
                let req = try decodeParams(TerminalIDRequest.self, from: line, method: method)
                try await handler.killTerminal(req)
                await respond(id: id, result: EmptyResponse())
            case ACPMethod.elicitationCreate:
                let req = try decodeParams(CreateElicitationRequest.self, from: line, method: method)
                await respond(id: id, result: await handler.createElicitation(req))
            default:
                let params = try? decoder.decode(ParamsEnvelope<JSONValue>.self, from: line).params
                let result = try await handler.extMethod(method: method, params: params)
                await respond(id: id, result: result)
            }
        } catch let error as ACPError {
            if case .rpc(let obj) = error {
                await respondError(id: id, error: obj)
            } else {
                await respondError(
                    id: id,
                    error: .init(code: JSONRPCErrorObject.internalError, message: String(describing: error)))
            }
        } catch {
            await respondError(
                id: id,
                error: .init(code: JSONRPCErrorObject.internalError, message: String(describing: error)))
        }
    }

    private func decodeParams<T: Decodable>(_ type: T.Type, from line: Data, method: String) throws -> T {
        do {
            return try decoder.decode(ParamsEnvelope<T>.self, from: line).params
        } catch {
            throw ACPError.rpc(
                .init(code: JSONRPCErrorObject.invalidParams, message: "bad params for \(method)"))
        }
    }

    private func respond<R: Encodable>(id: JSONRPCID, result: R) async {
        guard let payload = try? encoder.encode(OutgoingResponse(id: id, result: result)) else { return }
        try? await sendLine(payload)
    }

    private func respondError(id: JSONRPCID, error: JSONRPCErrorObject) async {
        guard let payload = try? encoder.encode(OutgoingErrorResponse(id: id, error: error)) else { return }
        try? await sendLine(payload)
    }

    private func finish(error: Error?) async {
        guard !isClosed else { return }
        isClosed = true
        closedError = error ?? ACPError.transportClosed
        readTask?.cancel()
        for (_, cont) in pending {
            cont.resume(throwing: error ?? ACPError.transportClosed)
        }
        pending.removeAll()
        transport.close()
        await handler.connectionDidClose(error: error)
    }
}

// MARK: - Typed agent API

extension ACPConnection {
    public func initialize(
        clientCapabilities: ClientCapabilities = ClientCapabilities(
            fs: FileSystemCapability(readTextFile: false, writeTextFile: false),
            terminal: false)
    ) async throws -> InitializeResponse {
        try await request(
            ACPMethod.initialize,
            InitializeRequest(clientCapabilities: clientCapabilities))
    }

    public func authenticate(methodId: String) async throws {
        let _: JSONValue? = try await request(ACPMethod.authenticate, AuthenticateRequest(methodId: methodId))
    }

    public func newSession(cwd: String, mcpServers: [McpServer] = []) async throws -> NewSessionResponse {
        try await request(ACPMethod.sessionNew, NewSessionRequest(cwd: cwd, mcpServers: mcpServers))
    }

    public func loadSession(
        sessionId: String, cwd: String, mcpServers: [McpServer] = []
    ) async throws -> LoadSessionResponse {
        try await request(
            ACPMethod.sessionLoad,
            LoadSessionRequest(sessionId: sessionId, cwd: cwd, mcpServers: mcpServers))
    }

    public func prompt(sessionId: String, blocks: [ContentBlock]) async throws -> PromptResponse {
        try await request(ACPMethod.sessionPrompt, PromptRequest(sessionId: sessionId, prompt: blocks))
    }

    public func cancel(sessionId: String) async throws {
        try await notify(ACPMethod.sessionCancel, CancelNotification(sessionId: sessionId))
    }

    public func setSessionMode(sessionId: String, modeId: String) async throws {
        let _: JSONValue? = try await request(
            ACPMethod.sessionSetMode, SetSessionModeRequest(sessionId: sessionId, modeId: modeId))
    }

    public func setSessionModel(sessionId: String, modelId: String) async throws {
        let _: JSONValue? = try await request(
            ACPMethod.sessionSetModel, SetSessionModelRequest(sessionId: sessionId, modelId: modelId))
    }
}
