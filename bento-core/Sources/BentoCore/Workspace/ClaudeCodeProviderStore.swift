import Foundation

/// A Claude Code provider configuration. Claude Code is launched via the
/// `claude-agent-acp` adapter, which reads Anthropic-style env vars to
/// decide which upstream API to call. Switching providers (Anthropic
/// official, z.ai GLM Coding Plan, custom OpenAI-compatible endpoints)
/// is done entirely by overriding these env vars at launch time.
///
/// Mapping (see https://docs.z.ai/devpack/tool/claude):
///   ANTHROPIC_BASE_URL          → upstream base URL
///   ANTHROPIC_AUTH_TOKEN        → bearer token / API key
///   ANTHROPIC_DEFAULT_OPUS_MODEL / SONNET / HAIKU → model aliases
///   API_TIMEOUT_MS              → request timeout
///
/// Empty fields are omitted from the env dictionary, letting the agent's
/// own defaults apply.
public struct ClaudeCodeProvider: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var authToken: String
    public var opusModel: String
    public var sonnetModel: String
    public var haikuModel: String
    public var apiTimeoutMs: String
    public var isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        baseURL: String = "",
        authToken: String = "",
        opusModel: String = "",
        sonnetModel: String = "",
        haikuModel: String = "",
        apiTimeoutMs: String = "",
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authToken = authToken
        self.opusModel = opusModel
        self.sonnetModel = sonnetModel
        self.haikuModel = haikuModel
        self.apiTimeoutMs = apiTimeoutMs
        self.isBuiltIn = isBuiltIn
    }

    /// The env vars to inject into `claude-agent-acp`'s process
    /// environment. Empty fields are dropped so the agent's built-in
    /// defaults remain in effect for anything not overridden.
    public var env: [String: String] {
        var e: [String: String] = [:]
        if !baseURL.isEmpty { e["ANTHROPIC_BASE_URL"] = baseURL }
        if !authToken.isEmpty { e["ANTHROPIC_AUTH_TOKEN"] = authToken }
        if !opusModel.isEmpty { e["ANTHROPIC_DEFAULT_OPUS_MODEL"] = opusModel }
        if !sonnetModel.isEmpty { e["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnetModel }
        if !haikuModel.isEmpty { e["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haikuModel }
        if !apiTimeoutMs.isEmpty { e["API_TIMEOUT_MS"] = apiTimeoutMs }
        return e
    }

    /// True when no overrides are set — selecting this provider is
    /// equivalent to running `claude` with its own defaults.
    public var isEmpty: Bool { env.isEmpty }

    /// Anthropic's official endpoint. Empty fields mean the agent's own
    /// defaults apply (it knows its own base URL + the user's login).
    public static let anthropic = ClaudeCodeProvider(
        id: "anthropic",
        name: "Anthropic",
        isBuiltIn: true
    )

    /// z.ai GLM Coding Plan. Values from the official integration guide
    /// (https://docs.z.ai/devpack/tool/claude). Models use the GLM-5.2
    /// family aliased onto Claude Code's opus/sonnet/haiku slots.
    public static let zai = ClaudeCodeProvider(
        id: "zai",
        name: "z.ai (GLM Coding Plan)",
        baseURL: "https://api.z.ai/api/anthropic",
        opusModel: "glm-5.2",
        sonnetModel: "glm-5.2",
        haikuModel: "glm-4.7",
        apiTimeoutMs: "3000000",
        isBuiltIn: true
    )

    public static let builtins: [ClaudeCodeProvider] = [.anthropic, .zai]
}

/// Persists the user's Claude Code provider list and the currently
/// selected one. Mirrors the `ProfileStore` pattern: `UserDefaults`-backed
/// `[Codable]`, seeded with built-ins on first launch, mergeable on schema
/// additions. Read by `AgentWorkspaceStore.presetFor(_:)` when launching
/// a `claude-code` pane.
@MainActor
public final class ClaudeCodeProviderStore: ObservableObject {
    public static let shared = ClaudeCodeProviderStore()

    @Published public var providers: [ClaudeCodeProvider] = []
    @Published public var activeID: String

    private let storageKey = "claude_code_providers_v1"
    private let activeKey = "claude_code_provider_active_v1"

    /// The currently selected provider. `nil` only if the store is empty
    /// (the user deleted everything including built-ins — `presetFor`
    /// treats that as "no overrides, use agent defaults").
    public var active: ClaudeCodeProvider? {
        providers.first { $0.id == activeID }
    }

    /// Loads from `UserDefaults`. Marked internal (not private) so tests
    /// can stand up isolated instances against the standard defaults.
    init() {
        let defaults = UserDefaults.standard

        // Active id — default to Anthropic (no-op override) on first launch.
        self.activeID = defaults.string(forKey: activeKey) ?? ClaudeCodeProvider.anthropic.id

        guard let data = defaults.data(forKey: storageKey) else {
            // First launch — seed built-ins.
            providers = ClaudeCodeProvider.builtins
            save()
            return
        }
        do {
            providers = try JSONDecoder().decode([ClaudeCodeProvider].self, from: data)
            mergeMissingBuiltIns()
            // Drop the active id if it no longer exists; fall back to Anthropic.
            if !providers.contains(where: { $0.id == activeID }) {
                activeID = ClaudeCodeProvider.anthropic.id
            }
            save()
        } catch {
            // Decode failed — back up the raw bytes and reseed built-ins
            // so the app keeps working without silently wiping the data.
            let stamp = Int(Date().timeIntervalSince1970)
            defaults.set(data, forKey: "\(storageKey)_broken_\(stamp)")
            providers = ClaudeCodeProvider.builtins
            activeID = ClaudeCodeProvider.anthropic.id
            save()
        }
    }

    /// Append any built-in provider whose id isn't already stored, so
    /// existing installs pick up providers added in later versions
    /// without clobbering the user's own edits.
    private func mergeMissingBuiltIns() {
        let existing = Set(providers.map(\.id))
        let missing = ClaudeCodeProvider.builtins.filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return }
        providers.append(contentsOf: missing)
    }

    public func setActive(_ id: String) {
        guard providers.contains(where: { $0.id == id }) else { return }
        activeID = id
        UserDefaults.standard.set(id, forKey: activeKey)
    }

    public func save() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        UserDefaults.standard.set(activeID, forKey: activeKey)
    }

    public func upsert(_ provider: ClaudeCodeProvider) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
        save()
    }

    public func delete(_ id: String) {
        providers.removeAll { $0.id == id }
        if activeID == id {
            activeID = providers.first?.id ?? ClaudeCodeProvider.anthropic.id
        }
        save()
    }

    public func resetToDefaults() {
        providers = ClaudeCodeProvider.builtins
        activeID = ClaudeCodeProvider.anthropic.id
        save()
    }
}
