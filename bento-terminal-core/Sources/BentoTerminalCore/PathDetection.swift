import Foundation

/// Detects file paths in terminal text and hit-tests them against a tapped /
/// clicked cell, for the tap-to-preview feature.
///
/// Everything here is pure text + integer math — no engine, no transport — so
/// it works identically for local / SSH / relay panes and inside or outside
/// tmux, and is unit-testable without a surface.
///
/// Coordinate model (same as TurnNavigator): `read_text(SCREEN)` returns
/// LOGICAL lines — ghostty joins soft-wrapped rows back into one line — while
/// taps land in VISUAL (wrapped) row space, top-aligned with the SCROLLBAR
/// action's `offset`/`total`. `PathHitTester` bridges the two with the same
/// `ceil(displayCells / cols)` accumulation the turn-scan nav validated on
/// device, then maps the in-row cell column to a character of the logical
/// line using terminal display width (CJK / emoji = 2 cells).
public enum PathDetector {

    /// One recognized path token.
    public struct Candidate: Equatable, Sendable {
        /// The path itself: quotes stripped, trailing punctuation and any
        /// `:line[:col]` suffix removed, `\ ` unescaped. What the fetch layer
        /// resolves against the pane's cwd.
        public let path: String
        /// `:12` / `:12:3` suffix if present (compiler-style references).
        public let line: Int?
        public let column: Int?
        /// True for tokens that are unambiguously path-shaped (`/…`, `~/…`,
        /// `./…`, `../…`, or quoted). False for bare relatives like
        /// `src/main.rs`, which the caller should stat-verify before surfacing
        /// UI (they're also common in non-path text).
        public let explicit: Bool
        /// Range of the visible token within the logical line (trailing junk
        /// trimmed, `:line` suffix kept) — what the UI highlights.
        public let range: Range<String.Index>
    }

    // MARK: - Token scan

    /// CJK / fullwidth PUNCTUATION that ends a path token. Terminal prose
    /// wraps paths in 、。，（）「」etc. with no spaces ("…sample.txt、notes.md）。"),
    /// so these must break the match. Deliberately narrow: CJK *ideographs*
    /// (and even fullwidth alphanumerics / halfwidth kana) stay legal path
    /// characters — `docs/渠道/说明文档.md` is a real path. Ranges: CJK Symbols
    /// and Punctuation (U+3000–303F), the punctuation slices of the
    /// Fullwidth/Halfwidth Forms block (，！？：；（）［］｛｝｜～·… but not
    /// ＡＢＣ１２３ or ｱｲｳ), curly quotes, ellipsis, middle dot.
    private static let cjkPunct =
        #"\x{3000}-\x{303F}"# +                                  // 、。〈〉《》「」【】…
        #"\x{FF01}-\x{FF0F}\x{FF1A}-\x{FF20}\x{FF3B}-\x{FF40}\x{FF5B}-\x{FF65}"# +
        #"\x{2018}-\x{201D}\x{2026}\x{00B7}"#

    /// Pattern priority: when matches overlap, the lowest wins (a quoted path
    /// beats the slashful fragment inside it, etc.).
    private static let patterns: [(explicit: Bool, regex: NSRegularExpression)] = {
        func re(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p)
        }
        return [
            // "quoted path with spaces" — inner group must contain a slash.
            (true, re(#""([^"\n]{1,512})""#)),
            (true, re(#"'([^'\n]{1,512})'"#)),
            // Absolute / home / dot-relative: `/…`, `~/…`, `./…`, `../…`.
            // Lookbehind rejects mid-token starts ("src/x" → bare pattern) and
            // URL authority slashes ("https://x" — first `/` follows `:`).
            (true, re(#"(?<![\w:/.~-])(?:~|\.{1,2})?/(?:\\ |[^\s"'`"# + cjkPunct + #"])+"#)),
            // Bare relative with at least one internal slash (optionally a
            // compiler-style `:line[:col]` suffix): src/main.rs:42:7. `\w`
            // matches ideographs (CJK file names are real); ASCII brackets are
            // NOT in the segment class — "x.md(注释)" must stop at the paren.
            // (Bracketed FILE names still work via the quoted patterns.)
            (false, re(#"(?<![\w./~@-])[\w+@-][\w.+@-]*(?:/[\w.+@#%-]+)+/?(?::\d{1,6}(?::\d{1,6})?)?"#)),
            // Bare filename with an extension: README.md, foo.tar.gz. The
            // extension must contain a letter so versions ("1.2.3") don't match.
            (false, re(#"(?<![\w./~@-])[\w+@-][\w.+@-]*\.[A-Za-z][A-Za-z0-9]{0,7}(?::\d{1,6}(?::\d{1,6})?)?(?![\w./~-])"#)),
        ]
    }()

    /// All path candidates in one logical line, best-priority-first per span.
    /// Exposed for tests; hit-testing callers use `candidate(in:atCell:)`.
    static func matches(in line: String) -> [(priority: Int, explicit: Bool, range: Range<String.Index>, quotedInner: Range<String.Index>?)] {
        guard !line.isEmpty else { return [] }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [(Int, Bool, Range<String.Index>, Range<String.Index>?)] = []
        for (i, entry) in patterns.enumerated() {
            entry.regex.enumerateMatches(in: line, range: full) { m, _, _ in
                guard let m, let r = Range(m.range, in: line) else { return }
                var inner: Range<String.Index>? = nil
                if m.numberOfRanges > 1, let ir = Range(m.range(at: 1), in: line) {
                    // Quoted patterns: the payload is the inner group, and it
                    // only counts as a path when it has a slash.
                    guard line[ir].contains("/") else { return }
                    inner = ir
                }
                out.append((i, entry.explicit, r, inner))
            }
        }
        return out
    }

    /// The candidate whose visible token covers `cell` (0-based display cell
    /// within the logical line), or nil.
    public static func candidate(in line: String, atCell cell: Int) -> Candidate? {
        guard cell >= 0, let idx = index(inLine: line, atCell: cell) else { return nil }
        let hits = matches(in: line)
            .filter { $0.range.contains(idx) }
            .sorted { ($0.priority, $0.range.lowerBound) < ($1.priority, $1.range.lowerBound) }
        guard let best = hits.first else { return nil }
        return clean(line: line, tokenRange: best.quotedInner ?? best.range,
                     displayRange: best.range, explicit: best.explicit)
    }

    /// Trim trailing junk, split off a `:line[:col]` suffix, unescape.
    private static func clean(line: String, tokenRange: Range<String.Index>,
                              displayRange: Range<String.Index>, explicit: Bool) -> Candidate? {
        var token = String(line[tokenRange])
        var end = tokenRange.upperBound

        // Trailing punctuation that's prose/markup, not path: strip repeatedly,
        // ASCII and the fullwidth/CJK equivalents ("见 x.md。"). Closers only
        // come off while unbalanced against the token body.
        func stripTrailing() {
            let junk = ".,;:!?'\"、。，；：！？…·’”"
            let closers: [Character: Character] = [
                ")": "(", "]": "[", "}": "{", ">": "<",
                "）": "（", "】": "【", "》": "《", "」": "「",
            ]
            while let last = token.last {
                if junk.contains(last) {
                    token.removeLast()
                } else if let opener = closers[last],
                          token.filter({ $0 == opener }).count < token.filter({ $0 == last }).count {
                    token.removeLast()
                } else {
                    break
                }
                end = line.index(before: end)
            }
        }
        stripTrailing()

        // `path:12` / `path:12:34` — compiler-style file references. The digits
        // stay inside the highlight range but come off the fetch path.
        var lineNo: Int?
        var colNo: Int?
        var path = token
        if let m = token.range(of: #":(\d{1,6})(:(\d{1,6}))?$"#, options: .regularExpression) {
            let suffix = token[m].dropFirst().split(separator: ":")
            lineNo = suffix.first.flatMap { Int($0) }
            colNo = suffix.count > 1 ? Int(suffix[1]) : nil
            path = String(token[..<m.lowerBound])
        }

        path = path.replacingOccurrences(of: "\\ ", with: " ")
        // A lone "/" or "~" or "." isn't a useful preview target.
        guard path.count > 1, path != "~/", path != "./", path != "../" else { return nil }
        // The display range starts at the raw match (including an opening
        // quote); highlight from the token start instead.
        let start = tokenRange.lowerBound
        guard start < end else { return nil }
        return Candidate(path: path, line: lineNo, column: colNo,
                         explicit: explicit, range: start..<end)
    }

    // MARK: - Cell ↔ index mapping (terminal display width)

    /// Display width of one character (sum of its scalars' cells — the same
    /// accounting `TurnNavigator.displayCells` uses, so hit-testing and wrap
    /// math can never disagree).
    private static func charCells(_ ch: Character) -> Int {
        ch.unicodeScalars.reduce(0) { $0 + TurnNavigator.scalarCells($1.value) }
    }

    /// The character index whose display cell span covers `cell`, or nil when
    /// `cell` is past the end of the line. Walks characters (not scalars) so
    /// the result is always a valid character boundary — regex ranges are
    /// character-aligned.
    public static func index(inLine line: String, atCell cell: Int) -> String.Index? {
        var acc = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            let w = charCells(line[idx])
            if acc + w > cell { return idx }
            acc += w
            idx = line.index(after: idx)
        }
        return nil
    }

    /// The display-cell span `[start, end)` of `range` within `line`.
    public static func cellSpan(inLine line: String, of range: Range<String.Index>) -> (start: Int, end: Int) {
        var acc = 0
        var start = 0
        var idx = line.startIndex
        while idx < range.upperBound, idx < line.endIndex {
            if idx == range.lowerBound { start = acc }
            acc += charCells(line[idx])
            idx = line.index(after: idx)
        }
        return (start, acc)
    }
}

/// Bridges a tap in visual-row space to a `PathDetector` candidate, from one
/// `read_text(SCREEN)` snapshot. Build once per snapshot (the surfaces cache
/// briefly for hover), then hit-test cheaply per event.
public struct PathHitTester {
    public struct Hit: Equatable {
        public let candidate: PathDetector.Candidate
        /// Highlight geometry: one span per visual row the token crosses,
        /// in ABSOLUTE visual-row space (same space as SCROLLBAR offset).
        /// `startCol..<endCol` are display cells.
        public let spans: [Span]
        public struct Span: Equatable {
            public let row: Int
            public let startCol: Int
            public let endCol: Int
        }
    }

    public let cols: Int
    /// Total visual rows of the snapshot — lets callers derive the viewport
    /// top (`total - viewportRows`) when no SCROLLBAR action arrived yet.
    public let totalVisualRows: Int
    private let lines: [String]
    private let starts: [Int]

    public init(screenText: String, cols: Int) {
        self.cols = max(1, cols)
        var lines: [String] = []
        var starts: [Int] = []
        var row = 0
        for piece in screenText.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(piece)
            lines.append(s)
            starts.append(row)
            row += TurnNavigator.visualRows(s, cols: cols)
        }
        self.lines = lines
        self.starts = starts
        self.totalVisualRows = row
    }

    /// Hit-test the display cell at (`absRow`, `col`), both 0-based.
    public func hit(absRow: Int, col: Int) -> Hit? {
        guard absRow >= 0, col >= 0, col < cols, let li = lineIndex(forRow: absRow) else { return nil }
        let line = lines[li]
        let cell = (absRow - starts[li]) * cols + col
        guard let cand = PathDetector.candidate(in: line, atCell: cell) else { return nil }
        let span = PathDetector.cellSpan(inLine: line, of: cand.range)
        var spans: [Hit.Span] = []
        var s = span.start
        while s < span.end {
            let r = s / cols
            let rowEnd = min(span.end, (r + 1) * cols)
            spans.append(Hit.Span(row: starts[li] + r, startCol: s - r * cols, endCol: rowEnd - r * cols))
            s = rowEnd
        }
        return Hit(candidate: cand, spans: spans)
    }

    /// The logical line whose wrapped rows contain `row` (greatest start ≤ row).
    private func lineIndex(forRow row: Int) -> Int? {
        guard !starts.isEmpty, row >= 0, row < totalVisualRows else { return nil }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
