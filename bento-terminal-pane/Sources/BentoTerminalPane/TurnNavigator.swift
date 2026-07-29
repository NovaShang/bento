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
/// Coordinate space: boundaries are VISUAL (wrapped) scrollbar rows, matching
/// `SCROLLBAR.offset`/`total`. `read_text(SCREEN)` returns *logical* lines —
/// ghostty unwraps soft-wrapped rows into one line each (confirmed on iOS:
/// `read_text` line count < scrollbar total by exactly the wrap count) — so a
/// boundary's LINE index is NOT its scrollbar row once anything wraps. We convert
/// by summing each preceding line's wrapped height (`ceil(displayCells / cols)`).
/// On a wide layout little wraps, so this ≈ the old line-index == row identity;
/// on a narrow layout (iPad portrait, or CJK = 2 cells/char) it corrects the
/// drift that otherwise makes jumps overshoot and chevrons show wrong.
struct TurnNavigator {
    /// Boundary rows in the scrollback (VISUAL row space), ascending. Empty when
    /// the pane's profile has no `promptBoundary` (no-op for unknown agents).
    private(set) var boundaries: [Int] = []

    /// Rescan `text` (a `read_text(SCREEN)` snapshot) for boundary rows. `cols` is
    /// the viewport width used to wrap logical lines into visual rows; `cols <= 0`
    /// (unknown) falls back to 1 row/line — exact when nothing wraps.
    mutating func scan(scrollback text: String, cols: Int = 0, boundaryPatterns: [String]) {
        guard !boundaryPatterns.isEmpty, !text.isEmpty else { boundaries = []; return }
        var rows: [Int] = []
        var visualRow = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if boundaryPatterns.contains(where: { AgentDetector.regexMatches($0, in: s) }) {
                rows.append(visualRow)   // the visual row where this line starts
            }
            visualRow += Self.visualRows(s, cols: cols)
        }
        boundaries = rows
    }

    /// Visual rows a logical line occupies when soft-wrapped at `cols` columns,
    /// using terminal display width (CJK / fullwidth / emoji = 2 cells). `cols<=0`
    /// → 1 (width unknown, or nothing to wrap).
    static func visualRows(_ line: String, cols: Int) -> Int {
        guard cols > 0 else { return 1 }
        let cells = displayCells(line)
        return max(1, (cells + cols - 1) / cols)
    }

    /// Terminal display width of `line` in cells (wcwidth-style approximation).
    static func displayCells(_ line: String) -> Int {
        var cells = 0
        for u in line.unicodeScalars { cells += scalarCells(u.value) }
        return cells
    }

    static func scalarCells(_ v: UInt32) -> Int {
        if v == 0 { return 0 }
        // Combining marks / zero-width joiners & spaces.
        if (0x0300...0x036F).contains(v) || (0x200B...0x200F).contains(v) || v == 0xFEFF { return 0 }
        // East Asian Wide / Fullwidth + emoji → 2 cells.
        if (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) ||
           (0x3041...0x33FF).contains(v) || (0x3400...0x4DBF).contains(v) ||
           (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v) ||
           (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) ||
           (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v) ||
           (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) ||
           (0x20000...0x3FFFD).contains(v) {
            return 2
        }
        return 1
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
