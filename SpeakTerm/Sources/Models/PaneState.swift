import Foundation

/// The three states a pane can be in
enum PaneState: Equatable {
    case working                          // Command is running, producing output
    case idle                             // No recent output, shell prompt visible
    case awaitingInput(profile: String)   // Waiting for user input (y/N prompt, etc.)
}

/// A profile that defines how to detect a specific tool's awaiting-input state
struct StateProfile: Identifiable {
    let id: String
    let name: String
    /// Regex patterns to match against the last N lines of output
    let outputPatterns: [String]
    /// Command name pattern (matched against pane_current_command)
    let commandPattern: String?
    /// Quick keys to show when this profile matches
    let quickKeys: [QuickKey]
}

struct QuickKey: Identifiable {
    let id: String
    let label: String
    let keys: String   // The string to send via send-keys
    let isEnter: Bool  // Whether to also send Enter after
}

/// Built-in profiles for common tools
enum BuiltInProfiles {
    static let all: [StateProfile] = [claudeCode, genericShell, gitInteractive]

    static let claudeCode = StateProfile(
        id: "claude-code",
        name: "Claude Code",
        outputPatterns: [
            "Do you want to proceed\\?",
            "Allow .* to",
            "\\(y/n\\)",
            "Press Enter to",
        ],
        commandPattern: "claude",
        quickKeys: [
            QuickKey(id: "y", label: "Yes", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "No", keys: "n", isEnter: true),
            QuickKey(id: "enter", label: "Enter", keys: "", isEnter: true),
        ]
    )

    static let genericShell = StateProfile(
        id: "shell",
        name: "Shell",
        outputPatterns: [
            "\\[y/N\\]",
            "\\[Y/n\\]",
            "Continue\\?",
            "\\(yes/no\\)",
            "Are you sure",
            "Proceed\\?",
        ],
        commandPattern: nil,
        quickKeys: [
            QuickKey(id: "y", label: "Y", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "N", keys: "n", isEnter: true),
            QuickKey(id: "enter", label: "Enter", keys: "", isEnter: true),
        ]
    )

    static let gitInteractive = StateProfile(
        id: "git",
        name: "Git",
        outputPatterns: [
            "Stage this hunk",
            "Discard this hunk",
            "Apply this hunk",
        ],
        commandPattern: "git",
        quickKeys: [
            QuickKey(id: "y", label: "y", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "n", keys: "n", isEnter: true),
            QuickKey(id: "q", label: "q", keys: "q", isEnter: true),
            QuickKey(id: "a", label: "a", keys: "a", isEnter: true),
        ]
    )
}
