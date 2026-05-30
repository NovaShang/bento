import Foundation

/// AgentPreset is the menu of "well-known" coding agents the wizard offers.
/// Mirrors BentoMenubar/Services/TmuxCLI.swift — keep both in sync.
public enum AgentPreset: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case opencode = "OpenCode"
    case codex = "Codex"
    case openclaw = "OpenClaw TUI"
    case hermes = "Hermes"
    case antigravity = "Antigravity"
    case none = "No agent (shell only)"
    case custom = "Custom command…"

    public var id: String { rawValue }

    /// nil = user-supplied (custom). Empty string = no agent, plain shell pane.
    public var command: String? {
        switch self {
        case .claudeCode:  return "claude"
        case .opencode:    return "opencode"
        case .codex:       return "codex"
        case .openclaw:    return "openclaw tui"
        case .hermes:      return "hermes"
        case .antigravity: return "agy"
        case .none:        return ""
        case .custom:      return nil
        }
    }
}

/// TmuxLayout is one of the canonical pane arrangements exposed as a visual
/// picker. Each maps to a (paneCount, tmuxLayoutName) pair.
public enum TmuxLayout: String, CaseIterable, Identifiable {
    case solo
    case sideBySide
    case topBottom
    case threeColumns
    case mainPlusStack
    case quadTile

    public var id: String { rawValue }

    public var paneCount: Int {
        switch self {
        case .solo: return 1
        case .sideBySide, .topBottom: return 2
        case .threeColumns, .mainPlusStack: return 3
        case .quadTile: return 4
        }
    }

    /// Argument to `tmux select-layout`. Nil means single pane (no select-layout needed).
    public var tmuxLayoutName: String? {
        switch self {
        case .solo: return nil
        case .sideBySide, .threeColumns: return "even-horizontal"
        case .topBottom: return "even-vertical"
        case .mainPlusStack: return "main-vertical"
        case .quadTile: return "tiled"
        }
    }

    public var symbol: String {
        switch self {
        case .solo: return "rectangle"
        case .sideBySide: return "rectangle.split.2x1"
        case .topBottom: return "rectangle.split.1x2"
        case .threeColumns: return "rectangle.split.3x1"
        case .mainPlusStack: return "sidebar.right"
        case .quadTile: return "square.grid.2x2"
        }
    }

    public var displayName: String {
        switch self {
        case .solo: return "Solo"
        case .sideBySide: return "Side by side"
        case .topBottom: return "Top / bottom"
        case .threeColumns: return "3 columns"
        case .mainPlusStack: return "Main + stack"
        case .quadTile: return "2 × 2 tile"
        }
    }
}

/// AgentSpec is the user input from the wizard.
public struct AgentSpec: Hashable {
    public var sessionName: String
    public var workingDir: String
    public var agentCommand: String   // resolved command (may be empty for shell-only)
    public var layout: TmuxLayout

    public init(sessionName: String, workingDir: String, agentCommand: String, layout: TmuxLayout) {
        self.sessionName = sessionName
        self.workingDir = workingDir
        self.agentCommand = agentCommand
        self.layout = layout
    }
}

extension AgentSpec {
    /// Build a shell script that creates a detached tmux session matching
    /// the spec. Send these lines over SSH BEFORE attaching via
    /// `tmux -CC new-session -A -s <name>`; the `-A` then attaches to the
    /// just-created session instead of creating a fresh empty one.
    public var setupScript: String {
        let name = Self.shellQuote(sessionName)
        let dir = Self.shellQuote(workingDir)
        let cmd = agentCommand.isEmpty ? "" : " " + Self.shellQuote(agentCommand)

        var lines: [String] = [
            "tmux new-session -d -s \(name) -c \(dir)\(cmd)"
        ]
        for _ in 1..<layout.paneCount {
            lines.append("tmux split-window -t \(name) -c \(dir)\(cmd)")
        }
        if let layoutName = layout.tmuxLayoutName {
            lines.append("tmux select-layout -t \(name) \(layoutName)")
        }
        return lines.joined(separator: "; ") + "\n"
    }

    private static func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
