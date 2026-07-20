import Foundation

/// How to launch an ACP agent. Replaces the terminal version's tmux setup
/// scripts — an agent is now just a stdio subprocess speaking ACP.
///
/// Launch commands follow the official ACP registry
/// (github.com/agentclientprotocol/registry, checked 2026-07-19); when a
/// vendor renames a package or flag, update from there.
public struct ACPAgentPreset: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    public var args: [String]
    /// Extra environment (e.g. model overrides). Values may reference
    /// existing env vars; passed through verbatim.
    public var env: [String: String]
    public var detail: String
    /// One-line install command shown when the binary is missing.
    public var installHint: String?
    /// Host-terminal command that signs this agent in, shown when the agent
    /// answers auth_required and in-protocol authenticate can't finish the
    /// job (most vendor logins are interactive/OAuth).
    public var loginHint: String?

    public init(
        id: String, name: String, command: String, args: [String],
        env: [String: String] = [:], detail: String = "", installHint: String? = nil,
        loginHint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.detail = detail
        self.installHint = installHint
        self.loginHint = loginHint
    }

    /// Verified live against opencode 1.18+ (`opencode acp`).
    public static let opencode = ACPAgentPreset(
        id: "opencode", name: "OpenCode", command: "opencode", args: ["acp"],
        detail: "opencode acp",
        installHint: "brew install sst/tap/opencode",
        loginHint: "opencode auth login")

    /// Official adapter (was @zed-industries/claude-code-acp — twice
    /// renamed; the live package is @agentclientprotocol/claude-agent-acp).
    public static let claude = ACPAgentPreset(
        id: "claude-code", name: "Claude Code", command: "claude-agent-acp", args: [],
        detail: "claude-agent-acp",
        installHint: "npm i -g @agentclientprotocol/claude-agent-acp",
        loginHint: "claude /login")

    /// The flag graduated: --experimental-acp → --acp.
    public static let geminiCLI = ACPAgentPreset(
        id: "gemini", name: "Gemini CLI", command: "gemini", args: ["--acp"],
        detail: "gemini --acp",
        installHint: "npm i -g @google/gemini-cli",
        loginHint: "gemini")

    public static let codex = ACPAgentPreset(
        id: "codex", name: "Codex", command: "codex-acp", args: [],
        detail: "codex-acp",
        installHint: "npm i -g @agentclientprotocol/codex-acp",
        loginHint: "codex login")

    public static let copilot = ACPAgentPreset(
        id: "copilot", name: "GitHub Copilot", command: "copilot", args: ["--acp"],
        detail: "copilot --acp",
        installHint: "npm i -g @github/copilot",
        loginHint: "copilot /login")

    public static let qwenCode = ACPAgentPreset(
        id: "qwen-code", name: "Qwen Code", command: "qwen",
        args: ["--acp", "--experimental-skills"],
        detail: "qwen --acp",
        installHint: "npm i -g @qwen-code/qwen-code",
        loginHint: "qwen")

    public static let goose = ACPAgentPreset(
        id: "goose", name: "Goose", command: "goose", args: ["acp"],
        detail: "goose acp",
        installHint: "brew install block-goose-cli",
        loginHint: "goose configure")

    public static let cursor = ACPAgentPreset(
        id: "cursor", name: "Cursor", command: "cursor-agent", args: ["acp"],
        detail: "cursor-agent acp",
        installHint: "curl https://cursor.com/install -fsS | bash",
        loginHint: "cursor-agent login")

    public static let kimi = ACPAgentPreset(
        id: "kimi", name: "Kimi CLI", command: "kimi", args: ["acp"],
        detail: "kimi acp",
        installHint: "github.com/MoonshotAI/kimi-cli releases")

    public static let amp = ACPAgentPreset(
        id: "amp", name: "Amp", command: "amp-acp", args: [],
        detail: "amp-acp",
        installHint: "github.com/tao12345666333/amp-acp releases")

    public static let builtin: [ACPAgentPreset] = [
        .opencode, .claude, .geminiCLI, .codex, .copilot,
        .qwenCode, .goose, .cursor, .kimi, .amp,
    ]
}
