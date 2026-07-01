import Foundation

/// Finds agent-turn boundaries by scanning the rendered scrollback for lines
/// matching a per-agent `promptBoundary` regex (e.g. Claude Code `^\s*❯ `), then
/// answers prev/next navigation relative to the current viewport row.
///
/// Pure and stateless-by-content: nothing is recorded at turn time — boundaries
/// are recomputed from the *current* scrollback, so mid-attach (we see all
/// history regardless of when we connected), reflow (re-scan gives fresh rows)
/// and trimming (scan only sees what's in the buffer) are handled for free.
///
/// Coordinate (verified by the Step-0 probe): `read_text(SCREEN)` returns the
/// whole scrollback, one line per row, top-aligned with the SCROLLBAR row space.
/// So a boundary's line index == its SCROLLBAR row, and the viewport-top row ==
/// `SCROLLBAR.offset` — a jump is just `reviewScroll(boundary - offset)` lines.
struct TurnNavigator {
    /// Boundary row indices in the scrollback, ascending. Empty when the pane's
    /// profile has no `promptBoundary` (graceful no-op for unknown agents).
    private(set) var boundaries: [Int] = []

    /// Rescan `text` (a `read_text(SCREEN)` snapshot) for boundary rows.
    mutating func scan(scrollback text: String, boundaryPatterns: [String]) {
        guard !boundaryPatterns.isEmpty, !text.isEmpty else { boundaries = []; return }
        var rows: [Int] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let s = String(line)
            if boundaryPatterns.contains(where: { AgentDetector.regexMatches($0, in: s) }) {
                rows.append(i)
            }
        }
        boundaries = rows
    }

    /// Nearest boundary strictly above the viewport top (the "jump up" target).
    func boundaryAbove(_ viewportTopRow: Int) -> Int? { boundaries.last { $0 < viewportTopRow } }
    /// Nearest boundary strictly below the viewport top (the "jump down" target).
    func boundaryBelow(_ viewportTopRow: Int) -> Int? { boundaries.first { $0 > viewportTopRow } }

    func canJumpUp(viewportTopRow: Int) -> Bool { boundaryAbove(viewportTopRow) != nil }
    /// Down is possible if there's a newer turn below, OR we're scrolled up off
    /// the live bottom (then "down" returns toward live).
    func canJumpDown(viewportTopRow: Int, atBottom: Bool) -> Bool {
        boundaryBelow(viewportTopRow) != nil || !atBottom
    }
}
