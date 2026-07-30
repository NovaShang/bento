import BentoFoundation
import Foundation

/// In-memory `TerminalTransport` — the test/preview double.
///
/// Tests push bytes as if they came off the wire and read back what was
/// written, so everything above the byte channel (control-mode parsing,
/// structure snapshots, the per-pane fan-out) runs headlessly with no pty, no
/// SSH, and no tmux. The twin of `InMemoryTmuxTransport` one layer up.
public final class InMemoryTerminalTransport: TerminalTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: TerminalConnectionState = .disconnected

    public var state: TerminalConnectionState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var onDataReceived: (@Sendable (Data) -> Void)?
    public var onStateChanged: (@Sendable (TerminalConnectionState) -> Void)?

    /// Everything the caller wrote, in order.
    public private(set) var written = Data()
    public private(set) var resizes: [(cols: Int, rows: Int)] = []
    public private(set) var shellStarts = 0

    /// Local by default so a test's `capture-pane` seeds aren't treated as
    /// expensive; flip it to exercise the metered path.
    public var isLocalLink: Bool = true

    public init() {}

    public func connect(host: BentoFoundation.Host) async {
        setState(.connected)
    }

    public func startShell(cols: Int, rows: Int) {
        lock.lock(); shellStarts += 1; lock.unlock()
        resizes.append((cols, rows))
    }

    public func write(_ data: Data) {
        lock.lock(); written.append(data); lock.unlock()
    }

    public func write(_ string: String) {
        if let data = string.data(using: .utf8) { write(data) }
    }

    public func resize(cols: Int, rows: Int) {
        resizes.append((cols, rows))
    }

    public func disconnect() {
        setState(.disconnected)
    }

    /// Deliver bytes as if the far end had sent them.
    public func feed(_ text: String) {
        onDataReceived?(Data(text.utf8))
    }

    /// What the caller wrote, as UTF-8 — for asserting on tmux command lines.
    public var writtenText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: written, as: UTF8.self)
    }

    private func setState(_ state: TerminalConnectionState) {
        lock.lock(); _state = state; lock.unlock()
        onStateChanged?(state)
    }
}
