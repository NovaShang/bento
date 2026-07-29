import Foundation

/// The keystroke-latency coalescer product B's terminal input rides — the
/// shell/runtime half of perf(input) `178690d` that the Go tmuxcm
/// DELIBERATELY punted upward ("batching belongs to the host layer above";
/// daemon/internal/tmuxcm/controlmode.go:113-116). Ported from SwiftTmux
/// `ControlMode.sendData`/`flushInputBuffer`, minus the per-pane map — one
/// coalescer binds to one pane surface, so its buffer is that pane's alone.
///
/// Leading-edge + trailing coalescing: the first byte of a burst flushes
/// IMMEDIATELY (interactive keystrokes pay no latency), and any bytes arriving
/// in the next 16 ms coalesce into one trailing flush (paste, key repeat).
/// All flushes run on one serial queue so per-pane byte order is call order —
/// a trailing paste flush can never overtake the leading keystroke.
public final class TmuxInputCoalescer: @unchecked Sendable {
    private let sink: @Sendable (Data) -> Void
    private let window: DispatchTimeInterval
    private let flushQueue = DispatchQueue(
        label: "com.bento.tmuxpane.input-flush", qos: .userInteractive)

    private let lock = NSLock()
    private var buffer = Data()
    /// True between the leading flush and the trailing flush — the coalescing
    /// window. A `send` that finds it open just appends and rides the pending
    /// trailing flush (no re-schedule), which IS the batching.
    private var windowOpen = false

    /// `sink` is the raw byte writer (`TmuxPaneRuntime.writeRaw`, off-main).
    /// `windowMs` is the coalescing window — 16 ms, matching the frozen product.
    public init(windowMs: Int = 16, sink: @escaping @Sendable (Data) -> Void) {
        self.sink = sink
        self.window = .milliseconds(windowMs)
    }

    /// Enqueue keystroke bytes. Cheap on the caller's thread (append + a bool),
    /// so it is safe to call from the surface's main-thread `keyDown`; the
    /// actual write happens on the flush queue.
    public func send(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let opensWindow = !windowOpen
        if opensWindow { windowOpen = true }
        lock.unlock()

        // Already coalescing: the bytes ride the trailing flush already pending.
        guard opensWindow else { return }
        flushQueue.async { [weak self] in self?.flush(closeWindow: false) }   // leading edge
        flushQueue.asyncAfter(deadline: .now() + window) { [weak self] in
            self?.flush(closeWindow: true)                                    // trailing
        }
    }

    private func flush(closeWindow: Bool) {
        lock.lock()
        // Only the trailing flush re-arms the leading edge for the next burst.
        if closeWindow { windowOpen = false }
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !out.isEmpty else { return }   // nothing typed during the window
        sink(out)
    }

    /// Drop any buffered bytes and re-arm (detach / teardown).
    public func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        windowOpen = false
        lock.unlock()
    }
}
