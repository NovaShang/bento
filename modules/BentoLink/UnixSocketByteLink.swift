#if os(macOS)
import Foundation
import Network
import os

/// Byte link over the daemon's local unix socket (~/.bento/acp.sock).
/// Same-user trust; the transport runs in plaintext mode on top.
public final class UnixSocketByteLink: AcpByteLink, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>

    private let incomingCont: AsyncThrowingStream<Data, Error>.Continuation
    private let path: String
    private let queue = DispatchQueue(label: "bento.acp.unix")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var closed = false

    public init(path: String) {
        self.path = path
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { cont = $0 }
        incomingCont = cont
    }

    public func open() async throws {
        let endpoint = NWEndpoint.unix(path: path)
        let connection = NWConnection(to: endpoint, using: .tcp)
        store(connection)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let done = OSAllocatedUnfairLock(initialState: false)
            func firstTime() -> Bool {
                done.withLock { was -> Bool in
                    let first = !was
                    was = true
                    return first
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if firstTime() { cont.resume() }
                case .failed(let error), .waiting(let error):
                    if firstTime() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        receiveNext()
    }

    private func receiveNext() {
        lock.lock()
        let connection = connection
        let isClosed = closed
        lock.unlock()
        guard let connection, !isClosed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.incomingCont.yield(data)
            }
            if isComplete || error != nil {
                self.incomingCont.finish(throwing: error)
                self.close()
                return
            }
            self.receiveNext()
        }
    }

    private func store(_ connection: NWConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    private func liveConnection() -> NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : connection
    }

    public func send(_ data: Data) async throws {
        guard let connection = liveConnection() else { throw AcpHostError.connectionClosed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
        }
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let connection = connection
        lock.unlock()
        connection?.cancel()
        incomingCont.finish()
    }
}
#endif
