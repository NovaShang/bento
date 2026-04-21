import Foundation

/// Monitors pane output to detect the three-state machine:
/// Working → Idle → AwaitingInput
///
/// Detection rules:
/// 1. tmux silence (no output for >silenceThreshold) → idle
/// 2. Output pattern matching (last N lines match profile regex) → awaitingInput
/// 3. Working = default (recent output within threshold)
final class StateDetectionService {
    private var lastOutputTime: [TmuxPaneID: Date] = [:]
    private(set) var recentLines: [TmuxPaneID: [String]] = [:]
    private let maxLines = 10
    private let silenceThreshold: TimeInterval = 5.0

    let profiles = BuiltInProfiles.all

    /// Call when new output arrives for a pane
    func recordOutput(pane: TmuxPaneID, data: Data) {
        lastOutputTime[pane] = Date()

        // Extract printable text lines from the data
        if let text = String(data: data, encoding: .utf8) {
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            var current = recentLines[pane] ?? []
            current.append(contentsOf: lines)
            // Keep only last N lines
            if current.count > maxLines {
                current = Array(current.suffix(maxLines))
            }
            recentLines[pane] = current
        }
    }

    /// Detect the current state of a pane
    func detectState(pane: TmuxPaneID, currentCommand: String?) -> PaneState {
        let now = Date()
        let lastOutput = lastOutputTime[pane] ?? .distantPast
        let lines = recentLines[pane] ?? []
        let recentText = lines.suffix(5).joined(separator: "\n")

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
    func quickKeys(for state: PaneState) -> [QuickKey] {
        guard case .awaitingInput(let profileID) = state else { return [] }
        return profiles.first { $0.id == profileID }?.quickKeys ?? []
    }

    /// Clear state for a pane (e.g., when it's closed)
    func clearPane(_ pane: TmuxPaneID) {
        lastOutputTime.removeValue(forKey: pane)
        recentLines.removeValue(forKey: pane)
    }
}
