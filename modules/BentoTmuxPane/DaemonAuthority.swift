import BentoWorkbench
import Foundation
import os

// Seam two, the server-authoritative side: in product B the daemon owns
// workspace structure ("a READING of the tmux session's structure, never
// client-side state"). Writes are verbs encoded onto the control channel;
// the ack only means "the read path will show it" — the UI always eats the
// statekv change stream, never an optimistic local tree mutation.

/// Encodes one structure verb as the daemon control frame
/// (`{"op":"structure","verb":{…}}`). A protocol on purpose: the concrete
/// wire shape lands together with the daemon's `structure` op (stage 2,
/// with the Go side) — until then DaemonAuthority stays testable against a
/// recording fake, and the shape is decided exactly once, against the
/// real op.
public protocol StructureVerbEncoding: Sendable {
    func encodeStructureFrame(_ verb: StructureVerb) throws -> Data
}

/// `StructureAuthority` for daemon-owned structure. Skeleton scope
/// (stage 1): the verb → frame write path and the snapshot → projection
/// read path, both ends left on named seams —
///   * `sendFrame` is where the BentoLink control channel plugs in;
///   * `ingest(stateValue:)` is what the statekv `statechanged`
///     subscription will call (both stage-2 wiring).
@MainActor
public final class DaemonAuthority: StructureAuthority {
    private static let log = Logger(subsystem: "com.bento.tmuxpane", category: "authority")

    /// Where encoded structure frames go. Fire-and-forget — stage 1's
    /// seam, kept for tests/previews that only record traffic.
    public typealias FrameSink = (Data) -> Void
    /// The stage-2 sink: the BentoLink control channel's acked send.
    /// Resolves with the structureApplied rev (the mirror rev that already
    /// includes the verb's effect) or throws on structureFailed.
    public typealias AckedFrameSink = @Sendable (Data) async throws -> UInt64

    private enum SendPath {
        case fireAndForget(FrameSink)
        case acked(AckedFrameSink)
    }

    private let encoding: any StructureVerbEncoding
    private let sendPath: SendPath

    /// Serializes acked sends: the daemon matches acks to ops by ARRIVAL
    /// ORDER on the stream (no correlation id), so frame N+1 must not pass
    /// frame N between apply() and the wire.
    private var applyChain: Task<Void, Never>?

    /// Ack surface (acked sink only): success carries the applied rev.
    /// Logging/error UI, never optimistic tree state — the tree only ever
    /// moves through `ingest`.
    public var onStructureResult: ((StructureVerb, Result<UInt64, Error>) -> Void)?
    /// Highest structureApplied rev seen — "the read path will show my last
    /// verb once lastState.rev reaches this".
    public private(set) var lastAppliedRev: UInt64 = 0

    /// Store slot the projection lands in (`WorkspaceEntry.id`); the
    /// snapshot itself has no numeric session id.
    public var entryID: Int

    /// Fan-out of a freshly projected tree. The consumer (the term shell's
    /// store adoption, stage 2) replaces its entry wholesale — the
    /// projection is the whole truth, there is nothing to merge.
    package var onProjection: ((AgentWorkspaceStore.WorkspaceEntry, TmuxStructureState) -> Void)?

    /// Fan-out of EVERY accepted mirror state, including ones with no
    /// projectable attached entry (an empty server after killing the last
    /// session still moves the rev). The multi-session term shell reads the
    /// whole server picture here; `onProjection` stays the attached-entry
    /// convenience.
    package var onState: ((TmuxStructureState) -> Void)?

    /// Last applied state — the monotonic-rev staleness guard, and what a
    /// late subscriber reads.
    public private(set) var lastState: TmuxStructureState?

    public init(encoding: any StructureVerbEncoding, entryID: Int = 0,
                sendFrame: @escaping FrameSink) {
        self.encoding = encoding
        self.entryID = entryID
        self.sendPath = .fireAndForget(sendFrame)
    }

    public init(encoding: any StructureVerbEncoding, entryID: Int = 0,
                ackedSend: @escaping AckedFrameSink) {
        self.encoding = encoding
        self.entryID = entryID
        self.sendPath = .acked(ackedSend)
    }

    // MARK: Write path

    public func apply(_ verb: StructureVerb) {
        let frame: Data
        do {
            frame = try encoding.encodeStructureFrame(verb)
        } catch {
            // A verb that can't encode is a programming error in the
            // encoding, not a user-visible failure mode — surface it loudly
            // in logs and drop it (there is no optimistic state to unwind,
            // by design).
            Self.log.error("structure verb failed to encode: \(String(describing: error))")
            return
        }
        switch sendPath {
        case .fireAndForget(let sink):
            sink(frame)
        case .acked(let sink):
            let previous = applyChain
            applyChain = Task { [weak self] in
                await previous?.value
                do {
                    let rev = try await sink(frame)
                    Self.log.info("structure verb applied at rev \(rev)")
                    self?.noteAck(verb, .success(rev))
                } catch {
                    Self.log.error("structure verb refused: \(String(describing: error))")
                    self?.noteAck(verb, .failure(error))
                }
            }
        }
    }

    private func noteAck(_ verb: StructureVerb, _ result: Result<UInt64, Error>) {
        if case .success(let rev) = result, rev > lastAppliedRev {
            lastAppliedRev = rev
        }
        onStructureResult?(verb, result)
    }

    // MARK: Read path

    /// Apply one statekv payload (JSON bytes, base64 already unwrapped by
    /// the transport). Stale revs — statekv is last-write-wins, but frames
    /// can arrive reordered across a reconnect — are dropped. Returns the
    /// projection when one applied, for callers that want it inline.
    @discardableResult
    public func ingest(stateValue: Data) -> Bool {
        guard let state = TmuxStructureDecoding.decode(stateValue) else { return false }
        if let last = lastState, state.rev <= last.rev { return false }
        lastState = state
        onState?(state)
        guard let entry = state.workspaceEntry(entryID: entryID) else { return false }
        onProjection?(entry, state)
        return true
    }
}
