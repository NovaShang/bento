import ACPHostKit
import Foundation

/// Catalog-level agent defaults: which agent a bare pane runs, and the
/// legacy/TUI command aliases that map wizard-era names onto the ACP
/// builtins. Scene-level knowledge (which agents exist and what runs), so
/// it lives with the catalog — the workspace store forwards to it for API
/// compatibility.
@MainActor
public enum AgentDefaults {
    static let defaultAgentKey = "acp_default_agent"

    /// API-key providers (Kimi/GLM/DeepSeek — Claude Code harness) resolve
    /// through the provider module; installed by `AcpPaneModule.install`.
    /// nil (bare store) = builtin presets only.
    public static var apiKeyPresetResolver: ((String) -> ACPAgentPreset?)?

    /// The agent a bare seed (no command) runs: the user's chosen default.
    public static var defaultPreset: ACPAgentPreset {
        let id = UserDefaults.standard.string(forKey: defaultAgentKey) ?? "opencode"
        if let preset = apiKeyPreset(matching: id) { return preset }
        return ACPAgentPreset.builtin.first { $0.id == id } ?? ACPAgentPreset.builtin[0]
    }

    /// Set the default agent by ACP preset id. The onboarding connect flow
    /// promotes the first successfully connected provider here, so the agent
    /// a bare pane spawns is the one the user actually signed into.
    public static func setDefaultAgentID(_ id: String) {
        UserDefaults.standard.set(id, forKey: defaultAgentKey)
    }

    public static func apiKeyPreset(matching commandOrID: String) -> ACPAgentPreset? {
        apiKeyPresetResolver?(commandOrID)
    }

    /// Legacy/TUI command names (the wizard's presets, `pane_current_command`
    /// style values) → the ACP builtin that actually speaks the protocol.
    /// `claude` the TUI is NOT an ACP agent; `claude-agent-acp` is.
    public static let commandAliases: [String: String] = [
        "claude": "claude-code", "claude-agent-acp": "claude-code",
        "codex": "codex", "codex-acp": "codex",
        "gemini": "gemini",
        "opencode": "opencode",
        "cursor-agent": "cursor",
        "copilot": "copilot",
        "amp": "amp", "amp-acp": "amp",
        "qwen": "qwen-code",
        "goose": "goose",
        "kimi": "kimi",
        // API-key providers (Claude Code harness): seed == preset id; the
        // actual resolution short-circuits through apiKeyPreset(matching:),
        // these entries just let AgentPreset.defaultSelection match.
        "kimi-cc": "kimi-cc", "glm-cc": "glm-cc", "deepseek-cc": "deepseek-cc",
    ]
}
