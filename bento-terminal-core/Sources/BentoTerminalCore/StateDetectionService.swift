import Foundation
import SwiftTmux

/// Monitors pane output to detect the three-state machine:
/// Working → Idle → AwaitingInput
///
/// Detection rules:
/// 1. tmux silence (no output for >silenceThreshold) → idle
/// 2. Output pattern matching (last N lines match profile regex) → awaitingInput
/// 3. Working = default (recent output within threshold)
@MainActor
public final class StateDetectionService {
    private var lastOutputTime: [TmuxPaneID: Date] = [:]
    private(set) var recentLines: [TmuxPaneID: [String]] = [:]
    /// Per-pane manual profile override (pane menu → Change Profile). When set,
    /// detection uses ONLY this profile's patterns and ignores command matching;
    /// nil = auto-detect (the default).
    private var paneProfileOverride: [TmuxPaneID: String] = [:]
    private let maxLines = 20
    private let silenceThreshold: TimeInterval = 5.0

    public init() {}

    var profiles: [StateProfile] { ProfileStore.shared.profiles }

    /// Force a pane to use a specific profile (nil restores auto-detect).
    public func setProfileOverride(_ profileID: String?, for pane: TmuxPaneID) {
        if let profileID { paneProfileOverride[pane] = profileID }
        else { paneProfileOverride.removeValue(forKey: pane) }
    }

    public func profileOverride(for pane: TmuxPaneID) -> String? { paneProfileOverride[pane] }

    /// Call when new output arrives for a pane
    public func recordOutput(pane: TmuxPaneID, data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        // Strip ANSI escape sequences for pattern matching
        let stripped = text.replacingOccurrences(
            of: "\\x1b\\[[\\d;]*[A-Za-z]|\\x1b\\][^\\x07]*\\x07|[\\x00-\\x08\\x0e-\\x1f]",
            with: "",
            options: .regularExpression
        )

        let lines = stripped.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Only update timestamp and buffer if there's real content
        guard !lines.isEmpty else { return }

        lastOutputTime[pane] = Date()
        var current = recentLines[pane] ?? []
        current.append(contentsOf: lines)
        if current.count > maxLines {
            current = Array(current.suffix(maxLines))
        }
        recentLines[pane] = current
    }

    /// Returns true if any of `patterns` matches `text` (case-insensitive regex).
    private func anyMatch(_ patterns: [String], in text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: text, range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Detect the current state of a pane. `title` is the pane_title; it's
    /// checked before output patterns (PRD §3.4 priority: Title → output).
    public func detectState(pane: TmuxPaneID, currentCommand: String?, title: String? = nil) -> PaneState {
        let now = Date()
        let lastOutput = lastOutputTime[pane] ?? .distantPast
        let lines = recentLines[pane] ?? []
        let recentText = lines.joined(separator: "\n")
        let titleText = title ?? ""

        // Manual override (pane menu → Change Profile): use only this profile's
        // patterns, ignoring command matching.
        if let overrideID = paneProfileOverride[pane],
           let profile = profiles.first(where: { $0.id == overrideID }) {
            if anyMatch(profile.titlePatterns, in: titleText) || anyMatch(profile.outputPatterns, in: recentText) {
                return .awaitingInput(profile: profile.id)
            }
            if now.timeIntervalSince(lastOutput) > silenceThreshold { return .idle }
            return .working
        }

        // Check for awaiting-input patterns. Two passes so a command-bound
        // profile (claude/codex/git/vim) always wins over the catch-all generic
        // shell profile, regardless of the order profiles happen to sit in the
        // array (built-ins merged into an existing install land at the end).
        for commandBoundPass in [true, false] {
            for profile in profiles {
                let isCommandBound = profile.commandPattern != nil
                guard isCommandBound == commandBoundPass else { continue }

                // Command-bound profiles only apply when the running command matches.
                if let cmdPattern = profile.commandPattern {
                    guard let cmd = currentCommand, cmd.contains(cmdPattern) else { continue }
                }

                // Title patterns take priority over output patterns (PRD §3.4).
                if anyMatch(profile.titlePatterns, in: titleText) || anyMatch(profile.outputPatterns, in: recentText) {
                    return .awaitingInput(profile: profile.id)
                }
            }
        }

        // Check silence threshold
        if now.timeIntervalSince(lastOutput) > silenceThreshold {
            return .idle
        }

        return .working
    }

    /// Get quick keys for a pane's current state
    public func quickKeys(for state: PaneState) -> [QuickKey] {
        guard case .awaitingInput(let profileID) = state else { return [] }
        return profiles.first { $0.id == profileID }?.quickKeys ?? []
    }

    /// Clear state for a pane (e.g., when it's closed)
    public func clearPane(_ pane: TmuxPaneID) {
        lastOutputTime.removeValue(forKey: pane)
        recentLines.removeValue(forKey: pane)
        paneProfileOverride.removeValue(forKey: pane)
    }

    /// Return the most recent N lines of stripped text for a pane, joined by
    /// newlines. Used as context for LLM-assisted command generation.
    public func recentText(for pane: TmuxPaneID, lines: Int) -> String {
        let buffer = recentLines[pane] ?? []
        let slice = buffer.suffix(lines)
        return slice.joined(separator: "\n")
    }
}
