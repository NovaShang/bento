import BentoTerminalPane
import Foundation
import SwiftTmux

// Seam one, client-side: one pane's byte pipe, backed by a control-mode
// connection this process owns rather than by the daemon's per-pane attach.
//
// The protocol is unchanged, so `TmuxPaneRuntime` above it did not move a
// line. What it loses is the daemon's sequenced event log — and with it the
// catch-up cursor, which existed because the daemon had a log to catch up
// ON. A control client has tmux itself instead: `capture-pane` is the
// scrollback, and the runtime already knows how to seed from it.

/// `TmuxByteTransport` over a live `TmuxSessionLink`.
@MainActor
public final class ControlModeTmuxTransport: TmuxByteTransport {
    private let pane: TmuxPaneID
    private weak var link: TmuxSessionLink?
    private var continuation: AsyncStream<TmuxPaneEvent>.Continuation?

    public init(pane: TmuxPaneID, link: TmuxSessionLink) {
        self.pane = pane
        self.link = link
    }

    /// `haveSeq` is ignored, and that is the honest answer rather than a
    /// silent one: there is no log to resume from, so every attach is cold
    /// and the runtime seeds its screen from `capture-pane`. Answering
    /// `replay: false` with both cursors at 0 is exactly how the runtime is
    /// told so — see `TmuxPaneRuntime.noteAttached`.
    nonisolated public func attach(haveSeq: UInt64) async throws -> TmuxAttachment {
        await MainActor.run { self.attachOnMain() }
    }

    private func attachOnMain() -> TmuxAttachment {
        continuation?.finish()

        var made: AsyncStream<TmuxPaneEvent>.Continuation!
        let events = AsyncStream<TmuxPaneEvent>(bufferingPolicy: .unbounded) { made = $0 }
        let cont = made!
        continuation = cont

        // Bind to THIS attach's continuation, never to self's slot: a late
        // chunk from a superseded attach must not leak into the new stream.
        link?.subscribe(pane: pane) { data in
            cont.yield(.output(data))
        }

        return TmuxAttachment(
            details: TmuxAttachDetails(running: true, headSeq: 0, startSeq: 0, replay: false),
            events: events)
    }

    nonisolated public func detach() {
        Task { @MainActor in self.detachOnMain() }
    }

    private func detachOnMain() {
        link?.unsubscribe(pane: pane)
        continuation?.finish()
        continuation = nil
    }

    /// Raw bytes, every one intact — the link hex-encodes them into
    /// `send-keys -H`, so `\r`, `\n` and ESC survive the protocol.
    nonisolated public func write(_ data: Data) {
        Task { @MainActor in self.link?.write(to: self.pane, data: data) }
    }

    nonisolated public func resize(cols: Int, rows: Int) {
        Task { @MainActor in self.link?.resize(pane: self.pane, cols: cols, rows: rows) }
    }

    /// The pane's scrollback — what stands in for the daemon's log replay.
    public func captureScrollback(lines: Int) async -> Data? {
        await link?.capture(pane: pane, lines: lines)
    }
}
