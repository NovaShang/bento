import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import Foundation

/// The "Connect your AI" catalog: one entry per service the user already pays
/// for. This is the onboarding-facing view over the agent world — cards speak
/// in subscriptions the user recognizes ("Claude", "ChatGPT"), not agent
/// binaries. Each entry ties together everything one Connect click needs:
/// what to install (into daemon-visible dirs), how the vendor's own CLI signs
/// in (the CLI opens the browser — we never run our own OAuth), how to read
/// back identity, and which ACP preset the verify-probe actually spawns.
///
/// Two species (validated 2026-07-22, see memory project-provider-connect):
/// - `.subscription`: the card represents one vendor account; connected =
///   a real ACP session starts (session/new succeeds, no -32000).
/// - `.byo` (OpenCode): an open-source agent that borrows third-party or
///   built-in free credentials. A zero-config install still creates sessions
///   (free models), so -32000 never fires — its green check means "runs",
///   and the identity line reports what it actually runs on.
public struct AIProvider: Identifiable, Sendable, Equatable {
    /// - `.subscription`: vendor CLI signs in (browser); green = real session.
    /// - `.byo` (OpenCode): open-source agent, own credential store.
    /// - `.apiKey` (Kimi/GLM/DeepSeek): Claude Code is the harness; the
    ///   vendor's Anthropic-compatible endpoint is injected via env vars and
    ///   the user pastes an API key. Validated 2026-07-22: env is honored
    ///   (no Keychain fallback → no false green), but session/new succeeds
    ///   regardless of the key — so verification sends one tiny prompt turn,
    ///   and a bad key hangs in SDK retries (verify needs a deadline).
    public enum Kind: Sendable, Equatable { case subscription, byo, apiKey }

    /// The paste-your-key configuration for `.apiKey` providers.
    public struct APIKeyConfig: Sendable, Equatable {
        /// Env var carrying the pasted key (Claude Code harness convention).
        public var keyEnvVar: String
        /// Static env: the vendor's Anthropic-compatible base URL (+ model
        /// overrides where the vendor documents them).
        public var harnessEnv: [String: String]
        /// Where the user gets a key ("Get a key →").
        public var consoleURL: String

        public init(keyEnvVar: String = "ANTHROPIC_AUTH_TOKEN",
                    harnessEnv: [String: String], consoleURL: String) {
            self.keyEnvVar = keyEnvVar
            self.harnessEnv = harnessEnv
            self.consoleURL = consoleURL
        }
    }

    /// How the vendor's sign-in runs. `.cli` commands are non-interactive to
    /// drive (they open the browser themselves and exit when done — validated
    /// with `codex login`). `.terminal` agents only sign in through their own
    /// interactive TUI; the fallback opens a real terminal window for that
    /// one step and the user hits Retry after.
    public enum LoginStyle: Sendable, Equatable {
        case cli(String)
        case terminal(String)
        case none
    }

    public var id: String
    /// Card title — the service, not the binary ("Claude", not claude-agent-acp).
    public var name: String
    /// Subtitle: the account the user recognizes.
    public var subtitle: String
    public var kind: Kind
    /// SF Symbol for the card mark.
    public var symbol: String
    /// Shown on the first screen, or folded under "More".
    public var firstScreen: Bool

    /// What the daemon spawns for panes AND what the verify-probe runs.
    public var acpPreset: ACPAgentPreset
    /// Seed command for AgentSpec (flows through AgentWorkspaceStore's
    /// commandAliases), e.g. "claude".
    public var seedCommand: String

    /// Install commands, run in order through a login shell. Must land the
    /// ACP binary in a daemon-visible dir (the probe checks; a miss surfaces
    /// the honest "installed but unreachable" fix rung, never a false green).
    public var installCommands: [String]
    /// Preferred when Homebrew is present (lands in /opt/homebrew/bin —
    /// always daemon-visible). nil = no brew route.
    public var brewInstallCommand: String?
    public var requiresNode: Bool

    public var login: LoginStyle
    /// Cheap non-interactive signed-in check (parsed by
    /// `ProviderIdentity.parse`), e.g. `claude auth status`.
    public var authStatusCommand: String?
    /// Present iff `kind == .apiKey`.
    public var apiKey: APIKeyConfig?
    public var docsURL: String

    public init(
        id: String, name: String, subtitle: String, kind: Kind, symbol: String,
        firstScreen: Bool, acpPreset: ACPAgentPreset, seedCommand: String,
        installCommands: [String], brewInstallCommand: String? = nil,
        requiresNode: Bool, login: LoginStyle, authStatusCommand: String? = nil,
        apiKey: APIKeyConfig? = nil, docsURL: String
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.kind = kind
        self.symbol = symbol
        self.firstScreen = firstScreen
        self.acpPreset = acpPreset
        self.seedCommand = seedCommand
        self.installCommands = installCommands
        self.brewInstallCommand = brewInstallCommand
        self.requiresNode = requiresNode
        self.login = login
        self.authStatusCommand = authStatusCommand
        self.apiKey = apiKey
        self.docsURL = docsURL
    }

    /// The preset to actually spawn/probe: for `.apiKey` providers, the
    /// harness env plus the user's key merged into the base preset.
    public func acpPreset(withKey key: String?) -> ACPAgentPreset {
        guard let config = apiKey else { return acpPreset }
        var preset = acpPreset
        preset.env = preset.env.merging(config.harnessEnv) { _, new in new }
        if let key, !key.isEmpty { preset.env[config.keyEnvVar] = key }
        return preset
    }
}

public extension AIProvider {
    /// First screen: the three subscriptions people actually hold, plus
    /// OpenCode as the open-source / no-subscription rung. Copilot and the
    /// rest fold under "More".
    static let claude = AIProvider(
        id: "claude-code", name: "Claude", subtitle: "Anthropic · Pro, Max, or API",
        kind: .subscription, symbol: "sparkle", firstScreen: true,
        acpPreset: .claude, seedCommand: "claude",
        // The TUI ships via the official curl installer (no Node); the ACP
        // adapter is npm-only. Both are needed: `claude` signs in (Keychain
        // credential, shared), `claude-agent-acp` runs the panes.
        installCommands: [
            "curl -fsSL https://claude.ai/install.sh | bash",
            "npm install -g @agentclientprotocol/claude-agent-acp",
        ],
        requiresNode: true,
        login: .cli("claude auth login"),
        authStatusCommand: "claude auth status",
        docsURL: "https://code.claude.com/docs/en/setup")

    static let codex = AIProvider(
        id: "codex", name: "ChatGPT · Codex", subtitle: "OpenAI · Plus, Pro, or API",
        kind: .subscription, symbol: "circle.hexagongrid", firstScreen: true,
        acpPreset: .codex, seedCommand: "codex",
        installCommands: ["npm install -g @openai/codex @agentclientprotocol/codex-acp"],
        requiresNode: true,
        // Validated end-to-end 2026-07-22: prints the URL, opens the browser,
        // exits on completion; `codex login status` → "Logged in using ChatGPT".
        login: .cli("codex login"),
        authStatusCommand: "codex login status",
        docsURL: "https://developers.openai.com/codex/cli")

    static let gemini = AIProvider(
        id: "gemini", name: "Gemini", subtitle: "Google · AI Pro or API",
        kind: .subscription, symbol: "diamond", firstScreen: true,
        acpPreset: .geminiCLI, seedCommand: "gemini",
        installCommands: ["npm install -g @google/gemini-cli"],
        requiresNode: true,
        // Gemini has no login subcommand — first interactive run does OAuth.
        login: .terminal("gemini"),
        docsURL: "https://geminicli.com/docs/get-started/installation/")

    static let opencode = AIProvider(
        id: "opencode", name: "OpenCode", subtitle: "Open source · any provider, or free built-in models",
        kind: .byo, symbol: "shippingbox", firstScreen: true,
        acpPreset: .opencode, seedCommand: "opencode",
        // The official curl script installs outside daemon-visible dirs;
        // prefer brew when present. The probe catches the mismatch either way.
        installCommands: ["curl -fsSL https://opencode.ai/install | bash"],
        brewInstallCommand: "brew install sst/tap/opencode",
        requiresNode: false,
        login: .none,
        docsURL: "https://opencode.ai/docs/")

    static let copilot = AIProvider(
        id: "copilot", name: "GitHub Copilot", subtitle: "Copilot subscription",
        kind: .subscription, symbol: "chevron.left.forwardslash.chevron.right", firstScreen: false,
        acpPreset: .copilot, seedCommand: "copilot",
        installCommands: ["npm install -g @github/copilot"],
        requiresNode: true,
        login: .terminal("copilot"),
        docsURL: "https://docs.github.com/copilot/how-tos/set-up/install-copilot-cli")

    static let cursor = AIProvider(
        id: "cursor", name: "Cursor", subtitle: "Cursor subscription",
        kind: .subscription, symbol: "cursorarrow", firstScreen: false,
        acpPreset: .cursor, seedCommand: "cursor-agent",
        installCommands: ["curl https://cursor.com/install -fsS | bash"],
        requiresNode: false,
        login: .cli("cursor-agent login"),
        docsURL: "https://cursor.com/docs/cli/installation")

    static let qwen = AIProvider(
        id: "qwen-code", name: "Qwen Code", subtitle: "Qwen · free tier or API",
        kind: .subscription, symbol: "q.circle", firstScreen: false,
        acpPreset: .qwenCode, seedCommand: "qwen",
        installCommands: ["npm install -g @qwen-code/qwen-code"],
        requiresNode: true,
        login: .terminal("qwen"),
        docsURL: "https://github.com/QwenLM/qwen-code")

    // API-key providers: Claude Code is the harness; the vendor's
    // Anthropic-compatible endpoint + the pasted key ride in via env.
    // Only the ACP adapter needs installing — no vendor CLI, no browser.

    static let kimi = AIProvider(
        id: "kimi-cc", name: "Kimi", subtitle: "Moonshot · API key",
        kind: .apiKey, symbol: "k.circle", firstScreen: false,
        acpPreset: ACPAgentPreset(
            id: "kimi-cc", name: "Kimi", command: "claude-agent-acp", args: [],
            detail: "Claude Code harness → Moonshot"),
        seedCommand: "kimi-cc",
        installCommands: ["npm install -g @agentclientprotocol/claude-agent-acp"],
        requiresNode: true,
        login: .none,
        apiKey: .init(
            harnessEnv: ["ANTHROPIC_BASE_URL": "https://api.moonshot.cn/anthropic"],
            consoleURL: "https://platform.moonshot.cn/console/api-keys"),
        docsURL: "https://platform.moonshot.cn/docs")

    static let glm = AIProvider(
        id: "glm-cc", name: "GLM", subtitle: "Zhipu · API key",
        kind: .apiKey, symbol: "g.circle", firstScreen: false,
        acpPreset: ACPAgentPreset(
            id: "glm-cc", name: "GLM", command: "claude-agent-acp", args: [],
            detail: "Claude Code harness → Zhipu"),
        seedCommand: "glm-cc",
        installCommands: ["npm install -g @agentclientprotocol/claude-agent-acp"],
        requiresNode: true,
        login: .none,
        // bigmodel.cn is the China coding-plan endpoint; the global Z.AI
        // equivalent is https://api.z.ai/api/anthropic.
        apiKey: .init(
            harnessEnv: ["ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic"],
            consoleURL: "https://open.bigmodel.cn/usercenter/apikeys"),
        docsURL: "https://docs.bigmodel.cn")

    static let deepseek = AIProvider(
        id: "deepseek-cc", name: "DeepSeek", subtitle: "DeepSeek · API key",
        kind: .apiKey, symbol: "d.circle", firstScreen: false,
        acpPreset: ACPAgentPreset(
            id: "deepseek-cc", name: "DeepSeek", command: "claude-agent-acp", args: [],
            detail: "Claude Code harness → DeepSeek"),
        seedCommand: "deepseek-cc",
        installCommands: ["npm install -g @agentclientprotocol/claude-agent-acp"],
        requiresNode: true,
        login: .none,
        // Model overrides per DeepSeek's Anthropic-compat docs.
        apiKey: .init(
            harnessEnv: [
                "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
                "ANTHROPIC_MODEL": "deepseek-chat",
                "ANTHROPIC_SMALL_FAST_MODEL": "deepseek-chat",
            ],
            consoleURL: "https://platform.deepseek.com/api_keys"),
        docsURL: "https://api-docs.deepseek.com")

    static let catalog: [AIProvider] = [
        .claude, .codex, .gemini, .opencode,
        .kimi, .glm, .deepseek,
        .copilot, .cursor, .qwen,
    ]

    /// API-key providers, for spawn-time preset resolution
    /// (AgentWorkspaceStore looks these up by seed command / id).
    static var apiKeyProviders: [AIProvider] { catalog.filter { $0.kind == .apiKey } }

    /// Masked display for a stored key: "····last4".
    static func maskedKey(_ key: String) -> String {
        "API key ····" + String(key.suffix(4))
    }
}

/// Parses each vendor's auth-status output into the card's identity line.
/// Pure functions — validated shapes live in the tests.
public enum ProviderIdentity {
    /// `claude auth status` → JSON {loggedIn, email, subscriptionType, …}.
    /// `codex login status` → "Logged in using ChatGPT" / "Not logged in".
    public static func parse(providerID: String, output: String) -> String? {
        switch providerID {
        case "claude-code":
            guard let start = output.firstIndex(of: "{"),
                  let data = String(output[start...]).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["loggedIn"] as? Bool == true
            else { return nil }
            var parts: [String] = []
            if let email = obj["email"] as? String { parts.append(email) }
            if let plan = obj["subscriptionType"] as? String, !plan.isEmpty {
                parts.append(plan.prefix(1).uppercased() + plan.dropFirst())
            }
            return parts.isEmpty ? "Signed in" : parts.joined(separator: " · ")
        case "codex":
            guard output.localizedCaseInsensitiveContains("logged in"),
                  !output.localizedCaseInsensitiveContains("not logged in")
            else { return nil }
            return output.localizedCaseInsensitiveContains("chatgpt")
                ? "ChatGPT account" : "Signed in"
        default:
            return nil
        }
    }
}
