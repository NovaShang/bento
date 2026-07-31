import BentoTerminalPane
import Foundation

// The runtime's ONLY talk-to-daemon surface. A tmux pane is a virtual
// acphost instance (`tmux:<target>:%N` — docs/tmux-host-design.md): attach
// with a catch-up cursor, raw bytes both ways, an explicit resize op, and
// an exit event when the pane (or its control client) goes away. The
// BentoLink-backed implementation is stage-2 work — it lands together with
// the daemon's wire shapes; everything above this protocol is testable
// against `InMemoryTmuxTransport` today.

/// A virtual tmux instance id, `tmux:<target>:%N`. Parsed from the RIGHT —
/// a pane id never contains a colon, a future `ssh://` target might
/// (mirrors the daemon's `parseTmuxAgentID`).
public struct TmuxVirtualInstanceID: Hashable, Sendable, CustomStringConvertible {
    public let target: String
    public let pane: TmuxPaneID

    public init(target: String, pane: TmuxPaneID) {
        self.target = target
        self.pane = pane
    }

    public init?(raw: String) {
        guard raw.hasPrefix("tmux:") else { return nil }
        let rest = raw.dropFirst("tmux:".count)
        guard let split = rest.lastIndex(of: ":"), split != rest.startIndex,
              let pane = TmuxPaneID(string: String(rest[rest.index(after: split)...]))
        else { return nil }
        self.target = String(rest[..<split])
        self.pane = pane
    }

    public var raw: String { "tmux:\(target):\(pane)" }
    public var description: String { raw }
}

/// One event off a pane's attach stream. Output chunks are WIRE UNITS —
/// exactly one daemon log entry each — so counting them IS the catch-up
/// cursor (raw terminal bytes have nowhere to carry a `_seq` stamp
/// in-band; see the daemon's tmuxPane.feed).
public enum TmuxPaneEvent: Sendable {
    case output(Data)
    /// The pane itself closed (message nil/empty) or its control client
    /// died under it. Terminal for this virtual instance either way — a
    /// later ensure+attach builds a fresh one.
    case exit(code: Int, message: String?)
}

/// What `attach` answers before the stream starts: the daemon's `attached`
/// control frame, minus fields tmux panes never carry.
public struct TmuxAttachDetails: Sendable, Equatable {
    public let running: Bool
    /// The log head at attach time. When `replay` is false the stream
    /// starts here — the client's cursor must jump, not count the gap.
    public let headSeq: UInt64
    /// Oldest unit still in the log (retention window start).
    public let startSeq: UInt64
    /// Whether the daemon is resending the tail from the caller's cursor.
    public let replay: Bool

    public init(running: Bool, headSeq: UInt64, startSeq: UInt64, replay: Bool) {
        self.running = running
        self.headSeq = headSeq
        self.startSeq = startSeq
        self.replay = replay
    }
}

/// An established attach: the handshake details plus the event stream. The
/// stream finishes after `.exit` or on detach.
public struct TmuxAttachment: Sendable {
    public let details: TmuxAttachDetails
    public let events: AsyncStream<TmuxPaneEvent>

    public init(details: TmuxAttachDetails, events: AsyncStream<TmuxPaneEvent>) {
        self.details = details
        self.events = events
    }
}

/// The byte pipe to ONE virtual tmux instance. Structure verbs are not
/// here on purpose — they belong to `DaemonAuthority` (seam two); this is
/// seam one's per-pane content channel only.
public protocol TmuxByteTransport: AnyObject, Sendable {
    /// Attach with the caller's catch-up cursor (0 = cold).
    func attach(haveSeq: UInt64) async throws -> TmuxAttachment
    func detach()
    /// Raw bytes to the pane's stdin (daemon: `send-keys -H`, every byte
    /// intact). No framing, no line discipline.
    func write(_ data: Data)
    /// The pane's cell size, from the RENDERER's authoritative grid
    /// (`TerminalSurfaceSize`) — never homemade cell math.
    func resize(cols: Int, rows: Int)
}

/// In-memory `TmuxByteTransport` — the test/preview double. Tests push
/// output/exit events and read back what the runtime wrote; events pushed
/// before an attach are queued and delivered once one exists (the daemon's
/// log replay, in miniature).
public final class InMemoryTmuxTransport: TmuxByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<TmuxPaneEvent>.Continuation?
    private var queued: [TmuxPaneEvent] = []

    // What the attach handshake should answer (mutable so a test can model
    // a hot log: head ahead of the caller's cursor).
    public var running = true
    public var headSeq: UInt64 = 0
    public var startSeq: UInt64 = 0
    public var replay = false
    /// When set, `attach` throws instead of answering.
    public var attachError: Error?

    // Recorded runtime → daemon traffic.
    public private(set) var written: [Data] = []
    public private(set) var resizes: [(cols: Int, rows: Int)] = []
    public private(set) var attaches: [UInt64] = []
    public private(set) var detachCount = 0

    public init() {}

    public func attach(haveSeq: UInt64) async throws -> TmuxAttachment {
        lock.lock()
        attaches.append(haveSeq)
        if let error = attachError {
            lock.unlock()
            throw error
        }
        let details = TmuxAttachDetails(
            running: running, headSeq: headSeq, startSeq: startSeq, replay: replay)
        let backlog = queued
        queued.removeAll()
        var newContinuation: AsyncStream<TmuxPaneEvent>.Continuation!
        let stream = AsyncStream<TmuxPaneEvent>(bufferingPolicy: .unbounded) {
            newContinuation = $0
        }
        continuation?.finish()
        continuation = newContinuation
        lock.unlock()
        for event in backlog { newContinuation.yield(event) }
        return TmuxAttachment(details: details, events: stream)
    }

    public func detach() {
        lock.lock()
        detachCount += 1
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
    }

    /// Simulates connection death: the event stream ends with NO exit frame
    /// — the exact shape LinkTmuxTransport produces when the daemon
    /// connection dies under a live attach (daemon restart, socket loss).
    public func dropConnection() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
    }

    public func write(_ data: Data) {
        lock.lock()
        written.append(data)
        lock.unlock()
    }

    public func resize(cols: Int, rows: Int) {
        lock.lock()
        resizes.append((cols, rows))
        lock.unlock()
    }

    /// Deliver one event to the attached stream (or queue it for the next
    /// attach).
    public func push(_ event: TmuxPaneEvent) {
        lock.lock()
        guard let cont = continuation else {
            queued.append(event)
            lock.unlock()
            return
        }
        lock.unlock()
        cont.yield(event)
        if case .exit = event { cont.finish() }
    }

    /// Convenience: one output unit.
    public func pushOutput(_ text: String) {
        push(.output(Data(text.utf8)))
    }

    /// The runtime → daemon bytes, concatenated as UTF-8 (test assertions).
    public var writtenText: String {
        lock.lock()
        defer { lock.unlock() }
        return written.map { String(decoding: $0, as: UTF8.self) }.joined()
    }
}
