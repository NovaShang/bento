import Foundation
import SwiftUI

/// ViewModel for a single workspace pane, managing its content stream and
/// input routing. Chat panes route input into the agent's composer through
/// the workspace store; the byte-stream/scrollback surface below is the
/// terminal-era machinery, kept compiling for the terminal pane's return
/// (hybrid workbench P1) — inert for chat panes.
@MainActor
public final class PaneViewModel: ObservableObject, Identifiable {
    public nonisolated let paneID: PaneID
    @Published public var pane: Pane
    @Published public var isActive: Bool = false
    @Published public var paneState: PaneState = .idle

    /// True when an agent pane has finished (.idle) but the user hasn't
    /// looked at it yet — the "done, unseen" state. Set when an agent pane
    /// goes idle while not focused; cleared when it's focused or leaves
    /// idle. Drives the distinct "done" dot.
    @Published public var agentFinishedUnseen: Bool = false

    /// Called when terminal output arrives for this pane. Setting this also
    /// replays the full history buffer so a freshly-bound surface repaints
    /// the scrollback rather than showing an empty screen.
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
    /// Let history overshoot the cap by this much before trimming, then drop
    /// a whole slab at once (front-removal on `Data` is O(n); per-chunk
    /// trimming was an O(n²) main-thread memmove storm).
    private static let historySlackBytes = 256 * 1024

    /// Strips screen/window-title escapes from this pane's byte stream
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
        if _history.count > Self.maxHistoryBytes + Self.historySlackBytes {
            _history.removeSubrange(0..<(_history.count - Self.maxHistoryBytes))
        }
    }

    /// The workspace store owning this pane's agent runtime; nil only in
    /// previews/tests.
    private weak var workspace: AgentWorkspaceStore?

    public nonisolated var id: PaneID { paneID }

    public init(pane: Pane, workspace: AgentWorkspaceStore?) {
        self.paneID = pane.id
        self.pane = pane
        self.isActive = pane.isActive
        self.workspace = workspace
    }

    /// Send raw input to this pane: printable text lands in the agent's
    /// composer; CR submits the draft.
    public func sendInput(_ data: Data) {
        workspace?.routeInput(data, to: paneID.raw)
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    public func updatePane(_ newPane: Pane) {
        // Equality-gate: the 2s poll re-applies an identical Pane most
        // cycles; republishing would ripple objectWillChange through every
        // subscribed view for no visible change.
        guard pane != newPane else { return }
        self.pane = newPane
    }

    /// The pane's working directory, read from the workspace record. Used by
    /// path-preview to resolve relative paths.
    public func currentWorkingDirectory() async -> String? {
        let path = workspace?.paneCwd(paneID.raw)
        pathPreviewLog.log("cwd query pane=\(self.paneID.description, privacy: .public) output=⟨\(path ?? "nil", privacy: .public)⟩")
        return path?.hasPrefix("/") == true ? path : nil
    }

    // MARK: - Scroll turn navigation (scan scrollback for agent-turn boundaries)

    /// Whether a jump to an older / newer turn is currently possible. Drives
    /// the macOS title-bar chevrons and the iOS edge pager, which HIDE when
    /// false. Derived from a content scan, not from recorded marks.
    @Published public private(set) var canJumpUp = false
    @Published public private(set) var canJumpDown = false

    /// Surface hooks, set by the host. `onReviewScroll(rows)` scrolls history
    /// by N rows (negative = older/up); `onScrollToLive()` snaps to the live
    /// bottom; `onReadScrollback()` returns the whole scrollback text.
    public var onReviewScroll: ((Int) -> Void)?
    public var onScrollToLive: (() -> Void)?
    public var onReadScrollback: (() -> String?)?

    /// Viewport geometry in ROWS from the surface's SCROLLBAR action.
    private var viewportTopRow = 0
    private var viewportRows = 0
    private var totalRows = 0
    private var nav = TurnNavigator()
    private var lastScanTotal = -1
    private var rescanWork: DispatchWorkItem?

    /// Pushed by the surface on each SCROLLBAR action (units = rows).
    public func noteScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        totalRows = Int(total)
        viewportTopRow = Int(offset)
        viewportRows = Int(len)
        if Int(total) != lastScanTotal { scheduleRescan() }
        recomputeAvailability()
    }

    private var atBottom: Bool { viewportTopRow + viewportRows >= totalRows }

    private func recomputeAvailability() {
        let up = nav.boundaryAbove(focusRow) != nil
        let down = nav.boundaryBelow(focusRow) != nil || !atBottom
        if up != canJumpUp { canJumpUp = up }
        if down != canJumpDown { canJumpDown = down }
    }

    /// Debounce so we don't rescan the whole scrollback on every streamed
    /// line — only once output settles (or just before a jump).
    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }

    /// Re-read the scrollback and re-find turn boundaries, using the pane's
    /// profile `promptBoundary` regexes (resolved from its current command).
    public func rescan() {
        let patterns = ProfileStore.shared.promptBoundary(forCommand: pane.currentCommand)
        let text = (patterns.isEmpty ? nil : onReadScrollback?()) ?? ""
        nav.scan(scrollback: text, cols: pane.width, boundaryPatterns: patterns)
        lastScanTotal = totalRows
        recomputeAvailability()
    }

    /// Land the boundary this many rows BELOW the viewport top, so the
    /// prompt itself stays visible (with a little context above it).
    private static let jumpLead = 3
    private var focusRow: Int { viewportTopRow + Self.jumpLead }

    public func jumpToOlderMark() {
        rescan()
        guard let row = nav.boundaryAbove(focusRow) else { return }
        jumpToBoundary(row)
    }

    /// Jump to the next (newer) turn below; past the newest, return to live.
    public func jumpToNewerMark() {
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
