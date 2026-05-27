import Foundation

/// TmuxCLI shells out to a tmux binary. The menubar app never proxies the
/// tmux protocol — the agent wizard builds a command sequence and `exec`s
/// it. Binary resolution (system vs bundled) lives in TmuxResolver.
enum TmuxCLI {
    /// Backwards-compatible accessor. Returns the resolved tmux URL, or
    /// nil if neither system nor bundled tmux is available. Callers that
    /// already handle nil for "tmux missing" keep working unchanged.
    static func locate() -> URL? { TmuxResolver.url() }

    static func listSessions() async -> [TmuxSession] {
        guard let tmux = locate() else { return [] }
        // Use `|` as the field separator. Tab worked in standalone tools but
        // Swift's `split(separator:)` overloading on Substring made the
        // tab-keyed split unreliable in the app build — pipe is unambiguous.
        // (Session names can't contain `|` because tmux disallows it.)
        // Format: name | attached | activity_unix_seconds
        let result: (out: String, err: String, code: Int32)
        do {
            result = try await runCapture(tmux, ["list-sessions", "-F", "#{session_name}|#{?session_attached,1,0}|#{session_activity}"])
        } catch {
            return []
        }
        if result.code != 0 { return [] }
        var sessions: [TmuxSession] = []
        for line in result.out.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            let activity: Date
            if let ts = Double(parts[2]), ts > 0 {
                activity = Date(timeIntervalSince1970: ts)
            } else {
                activity = .distantPast
            }
            sessions.append(TmuxSession(
                name: parts[0],
                attached: parts[1] == "1",
                lastActivity: activity
            ))
        }
        // Most recently active first — matches user intuition that "what I'm
        // currently working on" sits at the top.
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Build the shell command that creates the desired session. Running
    /// this in Terminal.app gives the user an attached view.
    static func buildAgentScript(spec: AgentSpec) -> String {
        let tmux = locate()?.path ?? "tmux"
        let name = shellQuote(spec.sessionName)
        let dir = shellQuote(spec.workingDir)
        // Empty agent command → start the user's shell so the pane is
        // interactive but no agent runs in it.
        let cmd = spec.agentCommand.isEmpty ? "" : " " + shellQuote(spec.agentCommand)

        var lines: [String] = [
            "\(tmux) new-session -d -s \(name) -c \(dir)\(cmd)"
        ]
        for _ in 1..<spec.layout.paneCount {
            lines.append("\(tmux) split-window -t \(name) -c \(dir)\(cmd)")
        }
        if let layoutName = spec.layout.tmuxLayoutName {
            lines.append("\(tmux) select-layout -t \(name) \(layoutName)")
        }
        lines.append("\(tmux) attach -t \(name)")
        return lines.joined(separator: "\n")
    }

    /// Open a new Terminal.app window running the given shell command.
    static func openInTerminal(command: String) async throws {
        // AppleScript is the simplest way to spawn a Terminal window with
        // arbitrary commands; avoids managing tty state ourselves.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        _ = try await run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
    }

    /// Attach to an existing tmux session in a new Terminal window.
    static func attach(session: String) async throws {
        let tmux = locate()?.path ?? "tmux"
        try await openInTerminal(command: "\(tmux) attach -t \(shellQuote(session))")
    }

    /// Kill a tmux session. Any Terminal windows attached to it exit.
    static func kill(session: String) async throws {
        guard let tmux = locate() else { return }
        _ = try await runCapture(tmux, ["kill-session", "-t", session])
    }

    /// Rename a tmux session.
    static func rename(session: String, to newName: String) async throws {
        guard let tmux = locate() else { return }
        _ = try await runCapture(tmux, ["rename-session", "-t", session, newName])
    }

    // MARK: - helpers

    private static func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func run(_ exe: URL, _ args: [String]) async throws -> String {
        try await runCapture(exe, args).out
    }

    private static func runCapture(_ exe: URL, _ args: [String]) async throws
        -> (out: String, err: String, code: Int32)
    {
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        return (
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self),
            proc.terminationStatus
        )
    }
}

// MARK: - presets

/// AgentPreset is the menu of "well-known" coding agents we offer in the
/// wizard. The command field is the shell invocation tmux will `sh -c` —
/// multi-word commands like "openclaw tui" are fine since tmux passes them
/// through the shell. Users with custom setups can pick `.custom`.
///
/// All commands here are verified against the agent's docs (May 2026):
///   claude       Anthropic Claude Code
///   opencode     anomalyco/opencode
///   codex        OpenAI @openai/codex
///   openclaw     OpenClaw (tui is the subcommand)
///   hermes       Nous Research Hermes Agent
///   agy          Google Antigravity CLI (binary IS named "agy")
enum AgentPreset: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case opencode = "OpenCode"
    case codex = "Codex"
    case openclaw = "OpenClaw TUI"
    case hermes = "Hermes"
    case antigravity = "Antigravity"
    case none = "No agent (shell only)"
    case custom = "Custom command…"

    var id: String { rawValue }

    var command: String? {
        switch self {
        case .claudeCode:  return "claude"
        case .opencode:    return "opencode"
        case .codex:       return "codex"
        case .openclaw:    return "openclaw tui"
        case .hermes:      return "hermes"
        case .antigravity: return "agy"
        case .none:        return ""    // empty cmd → plain shell pane
        case .custom:      return nil   // user-supplied
        }
    }
}

/// TmuxLayout is one of the canonical pane arrangements we expose as a
/// visual picker. Each maps to a (paneCount, tmuxLayoutName) pair.
enum TmuxLayout: String, CaseIterable, Identifiable {
    case solo
    case sideBySide          // 2 panes, even-horizontal
    case topBottom           // 2 panes, even-vertical
    case threeColumns        // 3 panes, even-horizontal
    case mainPlusStack       // 3 panes, main-vertical (1 big left + 2 stacked right)
    case quadTile            // 4 panes, tiled (2×2)

    var id: String { rawValue }

    var paneCount: Int {
        switch self {
        case .solo: return 1
        case .sideBySide, .topBottom: return 2
        case .threeColumns, .mainPlusStack: return 3
        case .quadTile: return 4
        }
    }

    /// Argument to `tmux select-layout`. Nil means no select-layout needed
    /// (single pane).
    var tmuxLayoutName: String? {
        switch self {
        case .solo: return nil
        case .sideBySide, .threeColumns: return "even-horizontal"
        case .topBottom: return "even-vertical"
        case .mainPlusStack: return "main-vertical"
        case .quadTile: return "tiled"
        }
    }

    /// SF Symbol used as the preview icon.
    var symbol: String {
        switch self {
        case .solo: return "rectangle"
        case .sideBySide: return "rectangle.split.2x1"
        case .topBottom: return "rectangle.split.1x2"
        case .threeColumns: return "rectangle.split.3x1"
        case .mainPlusStack: return "sidebar.right"
        case .quadTile: return "square.grid.2x2"
        }
    }

    var displayName: String {
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
struct AgentSpec {
    var sessionName: String
    var workingDir: String
    var agentCommand: String   // resolved command (may be empty for shell-only)
    var layout: TmuxLayout
}
