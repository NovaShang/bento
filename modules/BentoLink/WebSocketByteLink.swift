import Foundation

// MARK: - WebSocket link (relay path)

public final class WebSocketByteLink: AcpByteLink, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>

    private let incomingCont: AsyncThrowingStream<Data, Error>.Continuation
    private let makeURL: @Sendable () throws -> URL
    private let lock = NSLock()
    private var session: URLSession?
    private var ws: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var closed = false

    public init(makeURL: @escaping @Sendable () throws -> URL) {
        self.makeURL = makeURL
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { cont = $0 }
        incomingCont = cont
    }

    public func open() async throws {
        let url = try makeURL()
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        lock.lock()
        self.session = session
        self.ws = task
        lock.unlock()
        task.resume()

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let task = self?.currentWS() else { return }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .data(let d): self?.incomingCont.yield(d)
                    case .string(let s): self?.incomingCont.yield(Data(s.utf8))
                    @unknown default: break
                    }
                } catch {
                    self?.incomingCont.finish(
                        throwing: Self.upgradeError(task: task, fallback: error))
                    return
                }
            }
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                self?.currentWS()?.sendPing { _ in }
            }
        }
    }

    private func currentWS() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return ws
    }

    /// Recover the relay's actual verdict from a failed upgrade.
    ///
    /// URLSession collapses EVERY non-101 response into the same opaque
    /// `NSURLErrorBadServerResponse` ("There was a bad response from the
    /// server"), and that NSError's description embeds the full signed tunnel
    /// URL — device pubkey and signature included. Unmapped, that blob is what
    /// reached the transcript, and three completely different situations —
    /// the Mac being unreachable, this device no longer being authorized, and
    /// the agent genuinely exiting — all rendered as "Agent exited". The
    /// status code is sitting on the task's response; read it.
    private static func upgradeError(task: URLSessionWebSocketTask, fallback: Error) -> Error {
        guard let http = task.response as? HTTPURLResponse else { return fallback }
        switch http.statusCode {
        case 503:
            return AcpHostError.hostOffline
        case 401, 403:
            return AcpHostError.deviceNotAuthorized("HTTP \(http.statusCode)")
        case 101, 200..<300:
            // A clean upgrade that died later — the real error is the read's.
            return fallback
        default:
            return AcpHostError.protocolError(
                "the relay refused the tunnel (HTTP \(http.statusCode))")
        }
    }

    public func send(_ data: Data) async throws {
        guard let ws = currentWS() else { throw AcpHostError.connectionClosed }
        try await ws.send(.data(data))
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        receiveTask?.cancel()
        pingTask?.cancel()
        ws?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        incomingCont.finish()
    }
}
