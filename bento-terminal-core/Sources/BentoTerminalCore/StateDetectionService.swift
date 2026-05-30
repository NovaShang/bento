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
    private let maxLines = 20
    private let silenceThreshold: TimeInterval = 5.0

    public init() {}

    var profiles: [StateProfile] { ProfileStore.shared.profiles }

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

    /// Detect the current state of a pane
    public func detectState(pane: TmuxPaneID, currentCommand: String?) -> PaneState {
        let now = Date()
        let lastOutput = lastOutputTime[pane] ?? .distantPast
        let lines = recentLines[pane] ?? []
        let recentText = lines.joined(separator: "\n")

        // Check for awaiting input patterns
        for profile in profiles {
            // Check command pattern if specified
            if let cmdPattern = profile.commandPattern {
                if let cmd = currentCommand, !cmd.contains(cmdPattern) {
                    continue
                }
            }

            // Check output patterns
            for pattern in profile.outputPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(recentText.startIndex..., in: recentText)
                    if regex.firstMatch(in: recentText, range: range) != nil {
                        return .awaitingInput(profile: profile.id)
                    }
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
    }

    /// Return the most recent N lines of stripped text for a pane, joined by
    /// newlines. Used as context for LLM-assisted command generation.
    public func recentText(for pane: TmuxPaneID, lines: Int) -> String {
        let buffer = recentLines[pane] ?? []
        let slice = buffer.suffix(lines)
        return slice.joined(separator: "\n")
    }
}
