import Foundation

/// Per-pane output text buffer + manual profile override store.
///
/// This class used to be the terminal-era heuristic state detector
/// (silence/regex/title-glyph → Working/Idle/AwaitingInput). ACP made that
/// machinery obsolete — pane state now comes from the agent's own lifecycle
/// events (`TerminalViewModel.classifyPane` reading pendingPermission /
/// isTurnActive / phase), so the detector, the per-vendor rule engine hookup,
/// and the quick-keys lookup were removed. The rule DATA survives in
/// `StateProfile.agentRules` / `AgentRulePresets` (persisted profile schema,
/// and `TurnNavigator` still uses `AgentDetector.regexMatches`); heuristic
/// detection returns with real terminal panes (hybrid workbench P1).
///
/// What remains here:
///  - `recordOutput`/`recentText`: rolling stripped-text buffer per pane,
///    used as context for LLM-assisted (voice) command generation.
///  - `setProfileOverride`/`profileOverride`: the pane-menu "Change Profile"
///    choice, still consulted for quick-key/profile UI.
@MainActor
public final class StateDetectionService {
    private var recentLinesStore: [PaneID: [String]] = [:]
    /// Raw output buffered per pane, awaiting lazy processing. `recordOutput`
    /// runs on the hot output path (every chunk of every pane), so it must do
    /// no string/regex work — stripping and line-splitting happen on demand
    /// in `processPending`, only when something actually reads the lines.
    private var pendingRaw: [PaneID: Data] = [:]
    private var pendingArrival: [PaneID: Date] = [:]
    private let maxPendingBytes = 32 * 1024
    /// Per-pane manual profile override (pane menu → Change Profile);
    /// nil = auto (the default).
    private var paneProfileOverride: [PaneID: String] = [:]
    private let maxLines = 20

    /// Compiled once — `replacingOccurrences(options: .regularExpression)`
    /// recompiles the pattern on every call, which showed up as a top
    /// main-thread cost under heavy TUI output.
    private static let ansiStripRegex = try! NSRegularExpression(
        pattern: "\\x1b\\[[\\d;]*[A-Za-z]|\\x1b\\][^\\x07]*\\x07|[\\x00-\\x08\\x0e-\\x1f]"
    )

    public init() {}

    /// Force a pane to use a specific profile (nil restores auto-detect).
    public func setProfileOverride(_ profileID: String?, for pane: PaneID) {
        if let profileID { paneProfileOverride[pane] = profileID }
        else { paneProfileOverride.removeValue(forKey: pane) }
    }

    public func profileOverride(for pane: PaneID) -> String? { paneProfileOverride[pane] }

    /// Call when new output arrives for a pane. Hot path — only buffers the
    /// raw bytes; all stripping/splitting is deferred to `processPending`.
    public func recordOutput(pane: PaneID, data: Data) {
        guard !data.isEmpty else { return }
        var buf = pendingRaw[pane] ?? Data()
        buf.append(data)
        // Only the last `maxLines` lines ever matter; keep the tail. Trim only
        // after overshooting by a slab (not every chunk once at the cap), so heavy
        // output doesn't pay an O(maxPendingBytes) copy per chunk on the main
        // thread — same memmove-storm pattern as PaneViewModel's history trim.
        if buf.count > maxPendingBytes + maxPendingBytes {
            buf = Data(buf.suffix(maxPendingBytes))
        }
        pendingRaw[pane] = buf
        pendingArrival[pane] = Date()
    }

    /// Fold any buffered raw output for `pane` into `recentLinesStore`.
    private func processPending(_ pane: PaneID) {
        guard let raw = pendingRaw.removeValue(forKey: pane) else { return }
        pendingArrival.removeValue(forKey: pane)

        let text = String(decoding: raw, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        let stripped = Self.ansiStripRegex.stringByReplacingMatches(
            in: text, range: range, withTemplate: ""
        )

        let lines = stripped.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        var current = recentLinesStore[pane] ?? []
        current.append(contentsOf: lines)
        if current.count > maxLines {
            current = Array(current.suffix(maxLines))
        }
        recentLinesStore[pane] = current
    }

    /// Clear state for a pane (e.g., when it's closed)
    public func clearPane(_ pane: PaneID) {
        recentLinesStore.removeValue(forKey: pane)
        pendingRaw.removeValue(forKey: pane)
        pendingArrival.removeValue(forKey: pane)
        paneProfileOverride.removeValue(forKey: pane)
    }

    /// Return the most recent N lines of stripped text for a pane, joined by
    /// newlines. Used as context for LLM-assisted command generation.
    public func recentText(for pane: PaneID, lines: Int) -> String {
        processPending(pane)
        let buffer = recentLinesStore[pane] ?? []
        let slice = buffer.suffix(lines)
        return slice.joined(separator: "\n")
    }
}
