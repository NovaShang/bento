import Foundation
import SwiftUI
import SwiftTmux

/// ViewModel for a single tmux pane, managing its terminal output and input.
@MainActor
public final class PaneViewModel: ObservableObject, Identifiable {
    public nonisolated let paneID: TmuxPaneID
    @Published public var pane: Pane
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
            guard let onDataReceived, !_history.isEmpty else { return }
            onDataReceived(_history)
        }
    }

    /// Rolling buffer of every byte received for this pane. Capped so a
    /// long-running session doesn't grow without bound.
    nonisolated(unsafe) private var _history = Data()
    private static let maxHistoryBytes = 256 * 1024
    /// Let history overshoot the cap by this much before trimming, then drop a
    /// whole slab at once. Removing from the front of `Data` is O(n); trimming on
    /// every chunk once at the cap turned heavy output into an O(n²) main-thread
    /// memmove storm — the ~1s keystroke stall, since `feedData` runs on the main
    /// actor and blocks `keyDown`. Amortized, the front-shift runs ~once per slab
    /// received instead of once per chunk (linear total work).
    private static let historySlackBytes = 256 * 1024

    /// Strips screen/tmux window-title escapes from this pane's byte stream
    /// (see ScreenTitleStripper). Stateful, so it must persist across chunks.
    private let titleStripper = ScreenTitleStripper()

    /// Feed data to this pane — appended to history and forwarded if bound.
    public func feedData(_ data: Data) {
        let clean = titleStripper.strip(data)
        guard !clean.isEmpty else { return }
        appendHistory(clean)
        onDataReceived?(clean)
    }

    private func appendHistory(_ data: Data) {
        _history.append(data)
        // Trim only after overshooting the cap by a slab, then trim back to the
        // cap in one shot (see historySlackBytes) — never per chunk.
        if _history.count > Self.maxHistoryBytes + Self.historySlackBytes {
            _history.removeSubrange(0..<(_history.count - Self.maxHistoryBytes))
        }
    }

    private let tmuxService: TmuxControlMode

    public nonisolated var id: TmuxPaneID { paneID }

    public init(pane: Pane, tmuxService: TmuxControlMode) {
        self.paneID = pane.id
        self.pane = pane
        self.isActive = pane.isActive
        self.tmuxService = tmuxService
    }

    /// Send raw terminal input to this pane
    public func sendInput(_ data: Data) {
        tmuxService.sendData(to: paneID, data: data)
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    public func updatePane(_ newPane: Pane) {
        self.pane = newPane
    }

    // MARK: - Scroll-bookmark navigation (agent-turn history)

    /// One recorded scroll position: the scrollback row count captured the moment
    /// a new agent turn began (idle→working), so you can jump back to "where my
    /// Nth message was sent". See docs in TerminalViewModel.updatePaneStates.
    public struct ScrollMark: Identifiable, Equatable, Sendable {
        public let id = UUID()
        /// ghostty scrollback `total` at the last settled-idle frame before this
        /// turn started ≈ the absolute row where the prompt sat. Stable as long as
        /// the scrollback isn't trimmed off the top (default scrollback is large).
        public let anchorRow: UInt64
        /// Short hint for a future marks menu (unused by the v1 chevron UI).
        public let label: String
    }

    /// Per-pane bookmark stack, oldest first. Capped to bound memory.
    @Published public private(set) var scrollMarks: [ScrollMark] = []
    /// Whether a jump to an older / newer bookmark is currently possible. Drives
    /// the macOS title-bar chevrons and the iOS edge pager, which HIDE when false
    /// (e.g. no "down" at the live bottom).
    @Published public private(set) var canJumpUp = false
    @Published public private(set) var canJumpDown = false

    /// Surface scroll hooks, set by the host. `onReviewScroll(lines)` scrolls the
    /// history by N lines (negative = older/up) without snapping to bottom;
    /// `onScrollToLive()` snaps back to the live bottom.
    public var onReviewScroll: ((Int) -> Void)?
    public var onScrollToLive: (() -> Void)?

    /// Latest scrollbar geometry, pushed by the surface on each SCROLLBAR action.
    private var scrollTotal: UInt64 = 0
    private var scrollOffset: UInt64 = 0
    private var scrollLen: UInt64 = 0
    /// Candidate anchor + settle counter for the idle→working recorder.
    private var idleAnchorRow: UInt64 = 0
    private var idleStableCount = 0
    private static let maxMarks = 50
    /// Land the bookmarked row this many rows below the viewport top, so the
    /// prompt shows near the top and the answer flows below it.
    private static let jumpLead: UInt64 = 3

    /// Pushed by the surface on every SCROLLBAR action (main thread).
    public func noteScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        scrollTotal = total
        scrollOffset = offset
        scrollLen = len
        recomputeJumpAvailability()
    }

    /// Called once per state-detection poll with the freshly detected state.
    /// Tracks how long the pane has been settled-idle and snapshots the bottom
    /// row as the candidate anchor (the prompt sits at the bottom while idle).
    public func noteDetectedState(_ state: PaneState) {
        if case .idle = state {
            idleStableCount += 1
            idleAnchorRow = scrollTotal
        } else {
            idleStableCount = 0
        }
    }

    /// Drop a bookmark at the start of a new agent turn (the idle→working edge).
    /// Suppressed unless the pane was settled-idle (not a mid-turn flicker) and
    /// the bottom advanced past the previous mark (real new content).
    public func recordScrollMarkIfArmed(label: String) {
        guard idleStableCount >= 1, idleAnchorRow > 0 else { return }
        if let last = scrollMarks.last, idleAnchorRow <= last.anchorRow + 2 { return }
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        scrollMarks.append(ScrollMark(anchorRow: idleAnchorRow, label: String(clean.prefix(40))))
        if scrollMarks.count > Self.maxMarks {
            scrollMarks.removeFirst(scrollMarks.count - Self.maxMarks)
        }
        NSLog("[Bento.mark] recorded anchor=\(idleAnchorRow) total=\(scrollTotal) off=\(scrollOffset) len=\(scrollLen) count=\(scrollMarks.count)")
        recomputeJumpAvailability()
    }

    public func jumpToOlderMark() {
        let candidates = liveMarks.filter { targetTop(for: $0) + 1 < scrollOffset }
        guard let mark = candidates.max(by: { targetTop(for: $0) < targetTop(for: $1) }) else { return }
        performJump(to: mark)
    }

    public func jumpToNewerMark() {
        let below = liveMarks.filter { targetTop(for: $0) > scrollOffset + 1 }
        if let mark = below.min(by: { targetTop(for: $0) < targetTop(for: $1) }) {
            performJump(to: mark)
        } else {
            NSLog("[Bento.jump] newer: no mark below off=\(scrollOffset) total=\(scrollTotal) len=\(scrollLen) → scrollToLive")
            onScrollToLive?()   // no newer mark → return to the live bottom
        }
    }

    /// Marks still inside the live buffer (anchor not cleared / scrolled off top).
    private var liveMarks: [ScrollMark] {
        scrollMarks.filter { $0.anchorRow <= scrollTotal + 1 }
    }

    private var atBottom: Bool { scrollOffset + scrollLen >= scrollTotal }

    /// Target viewport-top offset to land this mark near the top of the screen.
    private func targetTop(for mark: ScrollMark) -> UInt64 {
        let maxOffset = scrollTotal > scrollLen ? scrollTotal - scrollLen : 0
        let raw = mark.anchorRow > Self.jumpLead ? mark.anchorRow - Self.jumpLead : 0
        return min(raw, maxOffset)
    }

    private func performJump(to mark: ScrollMark) {
        let target = targetTop(for: mark)
        let delta = Int(clamping: target) - Int(clamping: scrollOffset)
        NSLog("[Bento.jump] total=\(scrollTotal) off=\(scrollOffset) len=\(scrollLen) anchor=\(mark.anchorRow) target=\(target) delta=\(delta) marks=\(scrollMarks.map(\.anchorRow))")
        onReviewScroll?(delta)
    }

    private func recomputeJumpAvailability() {
        let marks = liveMarks
        let up = marks.contains { targetTop(for: $0) + 1 < scrollOffset }
        let down = !marks.isEmpty && (!atBottom || marks.contains { targetTop(for: $0) > scrollOffset + 1 })
        if up != canJumpUp { canJumpUp = up }
        if down != canJumpDown { canJumpDown = down }
    }
}
