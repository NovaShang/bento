import Foundation

/// The ACP backend needs no byte channel — agents talk JSON-RPC through
/// their own transports. This satisfies TerminalViewModel's transport slot
/// for workspace-backed sessions: always connected, discards writes, never
/// fails.
public final class NullTransport: TerminalTransport, @unchecked Sendable {
    public private(set) var state: TerminalConnectionState = .disconnected
    public var onDataReceived: (@Sendable (Data) -> Void)?
    public var onStateChanged: (@Sendable (TerminalConnectionState) -> Void)?

    public init() {}

    public func connect(host: Host) async {
        state = .connected
        onStateChanged?(.connected)
    }

    public func startShell(cols: Int, rows: Int) {}
    public func write(_ data: Data) {}
    public func write(_ string: String) {}
    public func resize(cols: Int, rows: Int) {}

    public func disconnect() {
        state = .disconnected
        onStateChanged?(.disconnected)
    }

    public func probeLiveness() async -> Bool { true }
}
