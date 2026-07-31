// Ported from frozen PaneViewModel.swift @ 8fa54b6^; data layer swapped, UI verbatim.
//
// The frozen original fed on tmux -CC `%output` and wrote via
// `TmuxControlMode.sendData`; this port feeds on `TmuxPaneRuntime.onOutput`
// (the daemon's per-pane byte pipe) and writes through `TmuxInputCoalescer` →
// `TmuxPaneRuntime.writeRaw` — the trunk's keystroke-latency path. Everything
// the shell binds (history replay on rebind, title stripping, scroll turn
// navigation, the published chrome state) is the frozen behavior.

import Foundation
import os
import SwiftUI
import BentoTerminalPane
import BentoTmuxPane

/// ViewModel for a single tmux pane, managing its terminal output and input.
@MainActor
public final class PaneViewModel: ObservableObject, Identifiable {
    public nonisolated let paneID: TmuxPaneID
    @Published public var pane: Pane {
        didSet {
            // Entering / leaving a fullscreen TUI decides whether turn nav applies,
            // and that flag arrives on a pane-list refresh — not on a scroll event —
            // so react here instead of waiting for the next SCROLLBAR action.
            guard pane.alternateOn != oldValue.alternateOn else { return }
            if pane.alternateOn { recomputeAvailability() } else { scheduleRescan() }
        }
    }
    @Published public var isActive: Bool = false
    @Published public var paneState: PaneState = .idle

    /// True when a coding-agent pane has finished (.idle) but the user hasn't
    /// looked at it yet — the "done, unseen" state (herdr's done vs idle). Set
    /// when an agent pane goes idle while not focused; cleared when it's focused
    /// or leaves idle. Drives the distinct "done" dot.
    @Published public var agentFinishedUnseen: Bool = false

    /// Called when terminal output arrives for this pane. Setting this also
    /// replays the full history buffer so a freshly-bound surface (e.g.
    /// after navigating away and back) repaints the scrollback rather than
    /// showing an empty screen until the next byte arrives.
    public nonisolated(unsafe) var onDataReceived: (@Sendable (Data) -> Void)? {
        didSet {
            // Snapshot under the lock — output may be appending concurrently on
            // the byte-pipe's delivery queue while a surface binds here.
            let replay = feedLock.withLock { _history }
            guard let onDataReceived, !replay.isEmpty else { return }
            onDataReceived(replay)
        }
    }

    /// Rolling buffer of every byte received for this pane. Capped so a
    /// long-running session doesn't grow without bound.
    nonisolated(unsafe) private var _history = Data()
    private nonisolated static let maxHistoryBytes = 256 * 1024
    /// Let history overshoot the cap by this much before trimming, then drop a
    /// whole slab at once. Removing from the front of `Data` is O(n); trimming on
    /// every chunk once at the cap turned heavy output into an O(n²) main-thread
    /// memmove storm — the ~1s keystroke stall, since `feedData` runs on the main
    /// actor and blocks `keyDown`. Amortized, the front-shift runs ~once per slab
    /// received instead of once per chunk (linear total work).
    private nonisolated static let historySlackBytes = 256 * 1024

    /// Strips screen/tmux window-title escapes from this pane's byte stream
    /// (see ScreenTitleStripper). Stateful, so it must persist across chunks —
    /// and since output can arrive off-main, every touch of it (and of
    /// `_history`) is serialized by `feedLock`.
    nonisolated(unsafe) private let titleStripper = ScreenTitleStripper()

    /// Guards `titleStripper` + `_history`. Both are stream-stateful, so a
    /// concurrent feed would corrupt escape-sequence tracking, not just race.
    private nonisolated let feedLock = OSAllocatedUnfairLock()

    /// Feed data to this pane — appended to history and forwarded if bound.
    ///
    /// `nonisolated` so pane output reaches the surface without a main-thread
    /// hop. The main thread is frozen for ~19ms on every keystroke (input
    /// method IPC), and routing echoes through it made them queue behind the
    /// very keystroke they were echoing.
    public nonisolated func feedData(_ data: Data) {
        // The strip + history append must be atomic as a pair: the stripper
        // consumes a prefix of the stream and history must record exactly what
        // it emitted, in the same order.
        feedLock.lock()
        let clean = titleStripper.strip(data)
        if !clean.isEmpty { appendHistory(clean) }
        feedLock.unlock()
        guard !clean.isEmpty else { return }
        // Outside the lock: the surface hands off to its own queue, and holding
        // a lock across a callback into unknown code invites deadlock.
        onDataReceived?(clean)
    }

    /// Caller must hold `feedLock`.
    private nonisolated func appendHistory(_ data: Data) {
        _history.append(data)
        // Trim only after overshooting the cap by a slab, then trim back to the
        // cap in one shot (see historySlackBytes) — never per chunk.
        if _history.count > Self.maxHistoryBytes + Self.historySlackBytes {
            // Known main-thread O(n) memmove; measured so we can see whether it
            // actually shows up in a stall or is amortized away.
            _history.removeSubrange(0..<(_history.count - Self.maxHistoryBytes))
        }
    }

    /// The pane's daemon-hosted byte pipe (`TmuxPaneRuntime` over
    /// `ControlModeTmuxTransport`) — the data layer under the frozen tmuxService.
    let runtime: TmuxPaneRuntime?

    /// Keystroke coalescing (leading edge + 16 ms trailing) between the
    /// surface's raw input and the wire — the perf(input) `178690d` half the
    /// Go side deliberately punted upward. Sits exactly where the frozen
    /// `sendInput` → `tmuxService.sendData` seam sat.
    private let inputCoalescer: TmuxInputCoalescer?

    public nonisolated var id: TmuxPaneID { paneID }

    public init(pane: Pane, runtime: TmuxPaneRuntime?) {
        self.paneID = pane.id
        self.pane = pane
        self.isActive = pane.isActive
        self.runtime = runtime
        if let runtime {
            self.inputCoalescer = TmuxInputCoalescer { [weak runtime] data in
                runtime?.writeRaw(data)
            }
            // The pipe's output units flow straight into the frozen feed path
            // (history + surface), off-main, exactly where `%output` landed.
            runtime.onOutput = { [weak self] data in self?.feedData(data) }
            // A runtime that already consumed output belonged to a background
            // window — this fresh view model's history is empty, so seed it
            // from tmux (one capture-pane including scrollback), exactly the
            // frozen product's seed on window switch.
            //
            // NOT a re-attach from seq 1. That asked the daemon to replay the
            // pane's whole event log, which is a per-chunk catch-up buffer,
            // not a scrollback store: its length grows with session lifetime
            // (a pane 1.5h old was 12012 entries) and every entry is its own
            // wire unit the surface renders on arrival — the whole history
            // visibly flying past on every Focus/Parallel switch. The frozen
            // product never had this: it replayed its OWN 256 KB rolling
            // buffer, constant volume. tmux is the scrollback authority, so
            // ask tmux; the log keeps its real job, catching up a client that
            // already holds a cursor (the daemon-restart re-attach).
            //
            // Unconditional now. The old `updateSeq > 0` guard skipped a
            // runtime that had consumed nothing, on the grounds that its first
            // attach WAS the seed — the daemon replayed a log it had opened
            // with its own capture-pane. There is no daemon and no log:
            // `ControlModeTmuxTransport` answers `replay: false, headSeq: 0`
            // and sends nothing, so a runtime rebuilt by a raced structure
            // parse came back at seq 0 and stayed permanently blank.
            // `seedFromCapture` single-flights, so asking twice costs nothing.
            runtime.seedFromCapture()
        } else {
            self.inputCoalescer = nil
        }
    }

    /// Send raw terminal input to this pane
    public func sendInput(_ data: Data) {
        inputCoalescer?.send(data)
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    public func updatePane(_ newPane: Pane) {
        // Equality-gate: the mirror re-applies an identical Pane most pushes;
        // republishing it would ripple objectWillChange through every subscribed
        // view for no visible change.
        guard pane != newPane else { return }
        self.pane = newPane
    }

    /// Data seam: call-time cwd fetch, wired by the owning TerminalViewModel
    /// to a fresh `tmuxpanes` pull filtered to this pane — the trunk's
    /// stand-in for the frozen per-pane display-message query (same
    /// control-channel read, same freshness).
    var fetchWorkingDirectory: (() async -> String?)?

    /// The pane's live working directory (`#{pane_current_path}`), queried at
    /// call time so it's never stale. nil on error / not reported. Used by
    /// path-preview to resolve relative paths — works over any transport since
    /// it rides the daemon's control channel.
    public func currentWorkingDirectory() async -> String? {
        let raw = await fetchWorkingDirectory?()
        pathPreviewLog.log("cwd query pane=\(self.paneID.description, privacy: .public) output=⟨\((raw ?? "<nil>").prefix(120), privacy: .public)⟩")
        guard let raw else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    // MARK: - Scroll turn navigation (scan scrollback for agent-turn boundaries)

    /// Whether a jump to an older / newer turn is currently possible. Drives the
    /// macOS title-bar chevrons and the iOS edge pager, which HIDE when false
    /// (e.g. no "down" at the live bottom). Derived from a content scan, not from
    /// recorded marks — so mid-attach history, reflow and trimming all just work.
    @Published public private(set) var canJumpUp = false
    @Published public private(set) var canJumpDown = false

    /// Surface hooks, set by the host. `onReviewScroll(rows)` scrolls history by N
    /// rows (negative = older/up); `onScrollToLive()` snaps to the live bottom;
    /// `onReadScrollback()` returns the whole scrollback text (read_text SCREEN).
    public var onReviewScroll: ((Int) -> Void)?
    public var onScrollToLive: (() -> Void)?
    public var onReadScrollback: (() -> String?)?

    /// Viewport geometry in ROWS from the surface's SCROLLBAR action. `offset` is
    /// the viewport-top row, top-aligned with the boundary scan (Step-0 probe).
    private var viewportTopRow = 0
    private var viewportRows = 0
    private var totalRows = 0
    private var nav = TurnNavigator()
    private var lastScanTotal = -1
    private var rescanWork: DispatchWorkItem?

    /// Pushed by the surface on each SCROLLBAR action (units = rows). Recomputes
    /// chevron availability cheaply; rescans (debounced) when the buffer grew.
    public func noteScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        totalRows = Int(total)
        viewportTopRow = Int(offset)
        viewportRows = Int(len)
        if Int(total) != lastScanTotal { scheduleRescan() }
        recomputeAvailability()
    }

    private var atBottom: Bool { viewportTopRow + viewportRows >= totalRows }

    /// Turn navigation walks the pane's SCROLLBACK for prompt boundaries, so it
    /// only means anything on the primary screen. A fullscreen TUI (Claude Code's
    /// fullscreen mode, vim, less) draws on the alternate screen and scrolls its
    /// own transcript internally — there are no boundaries below to find, and the
    /// scrollback still holds whatever was there before the TUI started. Hide the
    /// chevrons / edge pager rather than offer a jump that goes somewhere unrelated.
    private var turnNavApplies: Bool { !pane.alternateOn }

    private func recomputeAvailability() {
        let up = turnNavApplies && nav.boundaryAbove(focusRow) != nil
        let down = turnNavApplies && (nav.boundaryBelow(focusRow) != nil || !atBottom)
        if up != canJumpUp { canJumpUp = up }
        if down != canJumpDown { canJumpDown = down }
    }

    /// Debounce so we don't rescan the whole scrollback on every streamed line —
    /// only once output settles (or just before a jump).
    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }

    /// Re-read the scrollback and re-find turn boundaries, using the pane's
    /// profile `promptBoundary` regexes (resolved from its current command).
    public func rescan() {
        // Also skips the read_text of the whole scrollback that a scan needs —
        // a fullscreen agent pane repaints constantly, so this is the hot path.
        guard turnNavApplies else {
            nav = TurnNavigator()
            lastScanTotal = totalRows
            recomputeAvailability()
            return
        }
        let patterns = ProfileStore.shared.promptBoundary(forCommand: pane.currentCommand)
        let text = (patterns.isEmpty ? nil : onReadScrollback?()) ?? ""
        // `pane.width` is the terminal's column count = the wrap width, so the scan
        // can convert read_text's logical lines → visual (scrollbar) rows.
        nav.scan(scrollback: text, cols: pane.width, boundaryPatterns: patterns)
        lastScanTotal = totalRows
        recomputeAvailability()
    }

    /// Jump to the previous (older) agent turn above the viewport top.
    /// Land the boundary this many rows BELOW the viewport top, so the prompt
    /// itself stays visible (with a little context above it).
    private static let jumpLead = 3
    /// The row we consider "current" — a few rows into the viewport, i.e. where a
    /// jumped-to boundary sits. Querying boundaries relative to this (not the raw
    /// top) means after landing a boundary at the lead, UP/DOWN move to the
    /// previous/next turn instead of re-selecting the current one.
    private var focusRow: Int { viewportTopRow + Self.jumpLead }

    public func jumpToOlderMark() {
        guard turnNavApplies else { return }
        rescan()
        guard let row = nav.boundaryAbove(focusRow) else { return }
        jumpToBoundary(row)
    }

    /// Jump to the next (newer) turn below; past the newest, return to live.
    public func jumpToNewerMark() {
        guard turnNavApplies else { return }
        rescan()
        if let row = nav.boundaryBelow(focusRow) {
            jumpToBoundary(row)
        } else {
            onScrollToLive?()
        }
    }

    private func jumpToBoundary(_ row: Int) {
        onReviewScroll?(max(0, row - Self.jumpLead) - viewportTopRow)
    }
}
