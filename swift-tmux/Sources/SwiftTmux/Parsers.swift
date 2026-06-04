import Foundation

/// Stateless parsers for tmux's textual output. Use these on the response
/// body returned by `TmuxControlMode.send(_:)` (for `list-panes` /
/// `list-windows` / `list-sessions`), or on the raw bytes captured from a
/// shell where tmux ran directly.
public enum TmuxParsers {
    /// Parse the output of `list-panes` with the format
    /// `#{pane_id}:#{pane_width}:#{pane_height}:#{pane_left}:#{pane_top}:#{pane_active}:#{window_zoomed_flag}:#{pane_current_command}:#{pane_title}`.
    /// The zoom flag is per-window (every pane in a zoomed window reports 1);
    /// it sits before `pane_title` so the title (last field) may contain colons.
    public static func parsePaneList(_ output: String) -> [Pane] {
        output.split(separator: "\n").compactMap { line in
            // maxSplits 10 → 11 fields; the title (last) may itself contain
            // colons, so the mouse flags are placed before it.
            let parts = line.split(separator: ":", maxSplits: 10)
            guard parts.count >= 6,
                  let paneID = TmuxPaneID(string: String(parts[0])),
                  let width = Int(parts[1]),
                  let height = Int(parts[2]),
                  let x = Int(parts[3]),
                  let y = Int(parts[4]) else {
                return nil
            }
            let isActive = parts[5] == "1"
            let isZoomed = parts.count > 6 && parts[6] == "1"
            let command = parts.count > 7 ? String(parts[7]) : nil
            let mouseAny = parts.count > 8 && parts[8] == "1"
            let mouseSGR = parts.count > 9 && parts[9] == "1"
            let title = parts.count > 10 ? String(parts[10]) : nil

            return Pane(
                id: paneID,
                width: width,
                height: height,
                x: x,
                y: y,
                isActive: isActive,
                isZoomed: isZoomed,
                currentCommand: command,
                title: title,
                mouseAny: mouseAny,
                mouseSGR: mouseSGR
            )
        }
    }

    /// Parse the output of `list-windows` with the format
    /// `#{window_id}:#{window_name}:#{window_layout}:#{window_active}`.
    public static func parseWindowList(_ output: String) -> [TmuxWindow] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 3)
            guard parts.count >= 2,
                  let winID = TmuxWindowID(string: String(parts[0])) else {
                return nil
            }
            let name = String(parts[1])
            let layout = parts.count > 2 ? String(parts[2]) : nil
            let isActive = parts.count > 3 && parts[3] == "1"

            return TmuxWindow(
                id: winID,
                name: name,
                panes: [],
                layout: layout,
                isActive: isActive
            )
        }
    }

    /// Extract session names from `tmux ls` output read over an interactive
    /// PTY (with shell echo, OSC title escapes, CRLF endings, syntax-highlight
    /// noise). The caller wraps the command in two markers; this function
    /// slices strictly between them.
    ///
    /// **Caller contract:** build markers as two concatenated halves (e.g.
    /// `"__S_xxx_"` + `"_GO__"`). The runtime `printf '%s%s' ...` will emit
    /// the contiguous marker, but the PTY echo of the *command line* renders
    /// the halves as separate single-quoted shell tokens, never adjacent —
    /// so a `contains(marker)` check can't mismatch on the echo.
    ///
    /// **Why the markers matter:** without them, parsers either lose the
    /// first session (eaten by an OSC sequence the shell injected) or stop
    /// after the first line (CRLF being a single Swift grapheme cluster).
    public static func parseTmuxLs(
        _ output: String,
        startMarker: String,
        endMarker: String
    ) -> [String] {
        var names: [String] = []
        let body: String
        if let s = output.range(of: startMarker),
           let e = output.range(of: endMarker),
           s.upperBound < e.lowerBound {
            body = String(output[s.upperBound..<e.lowerBound])
        } else if let e = output.range(of: endMarker) {
            body = String(output[..<e.lowerBound])
        } else {
            body = output
        }
        let cleaned = ANSI.strip(body)
        // `$0.isNewline` is critical: Swift treats CRLF as one grapheme
        // cluster, so a comparison against `"\n"` alone would yield one giant
        // line containing every session.
        for rawLine in cleaned.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            // Each tmux ls line has a colon between name and stats.
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...]
            // Tail must look like `: N windows`; otherwise a banner / MOTD
            // line that happens to contain a colon would masquerade as a
            // session.
            guard rest.contains("windows") else { continue }
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
            else { continue }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
}
