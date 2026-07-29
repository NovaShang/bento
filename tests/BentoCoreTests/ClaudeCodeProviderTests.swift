import XCTest
@testable import BentoCore

/// Tests for the Claude Code provider store and the env injection into
/// `AgentWorkspaceStore.presetFor(_:)`. The store is a process-wide
/// singleton backed by UserDefaults, so each test clears the storage
/// keys in setUp/tearDown to start from a known state.
@MainActor
final class ClaudeCodeProviderTests: XCTestCase {
    private static let providersKey = "claude_code_providers_v1"
    private static let activeKey = "claude_code_provider_active_v1"

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: Self.providersKey)
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.providersKey)
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
    }

    // MARK: - Provider.env

    func testProviderEnvOmitsEmptyFields() {
        let p = ClaudeCodeProvider(
            id: "x", name: "X",
            baseURL: "https://example.com", authToken: "tok",
            opusModel: "glm-5.2"
            // sonnetModel / haikuModel / apiTimeoutMs left blank
        )
        XCTAssertEqual(p.env, [
            "ANTHROPIC_BASE_URL": "https://example.com",
            "ANTHROPIC_AUTH_TOKEN": "tok",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.2",
        ])
    }

    func testAnthropicBuiltinIsEmpty() {
        // The Anthropic preset carries no overrides — selecting it should
        // leave the agent's own defaults in effect.
        XCTAssertTrue(ClaudeCodeProvider.anthropic.isEmpty)
        XCTAssertEqual(ClaudeCodeProvider.anthropic.env, [:])
    }

    func testZaiBuiltinCarriesExpectedEnv() {
        let env = ClaudeCodeProvider.zai.env
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        XCTAssertNotNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL"])
        XCTAssertNotNil(env["ANTHROPIC_DEFAULT_SONNET_MODEL"])
        XCTAssertNotNil(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
        XCTAssertEqual(env["API_TIMEOUT_MS"], "3000000")
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"], "auth token is user-supplied, not in the builtin")
    }

    // MARK: - Store seed / active

    func testFirstLaunchSeedsBuiltins() {
        let store = ClaudeCodeProviderStore()
        XCTAssertEqual(store.providers.map(\.id), ["anthropic", "zai"])
        XCTAssertEqual(store.activeID, "anthropic", "defaults to Anthropic on first launch")
        XCTAssertEqual(store.active?.id, "anthropic")
    }

    func testSetActivePersistsAcrossInstances() {
        let first = ClaudeCodeProviderStore()
        first.setActive("zai")

        let second = ClaudeCodeProviderStore()
        XCTAssertEqual(second.activeID, "zai")
    }

    func testSetActiveRejectsUnknownID() {
        let store = ClaudeCodeProviderStore()
        let before = store.activeID
        store.setActive("does-not-exist")
        XCTAssertEqual(store.activeID, before, "no-op when the id isn't in the store")
    }

    func testFallsBackToAnthropicWhenActiveDeleted() {
        let store = ClaudeCodeProviderStore()
        store.setActive("zai")
        store.delete("zai")
        XCTAssertEqual(store.activeID, "anthropic")
        XCTAssertNil(store.providers.first { $0.id == "zai" })
    }

    // MARK: - Upsert

    func testUpsertAppendsThenUpdates() {
        let store = ClaudeCodeProviderStore()
        let custom = ClaudeCodeProvider(
            id: "custom", name: "My Provider",
            baseURL: "https://api.example.com", authToken: "secret"
        )
        store.upsert(custom)
        XCTAssertEqual(store.providers.last?.id, "custom")

        var updated = custom
        updated.name = "Renamed"
        store.upsert(updated)
        XCTAssertEqual(store.providers.count, 3, "upsert in place, not append")
        XCTAssertEqual(store.providers.last?.name, "Renamed")
    }

    // MARK: - Reset

    func testResetToDefaultsReplacesCustoms() {
        let store = ClaudeCodeProviderStore()
        store.upsert(ClaudeCodeProvider(id: "tmp", name: "Tmp"))
        XCTAssertEqual(store.providers.count, 3)

        store.resetToDefaults()
        XCTAssertEqual(store.providers.map(\.id), ["anthropic", "zai"])
        XCTAssertEqual(store.activeID, "anthropic")
    }

    // MARK: - presetFor env injection

    private func makeWorkspace(store: ClaudeCodeProviderStore) -> AgentWorkspaceStore {
        let workspace = AgentWorkspaceStore(persistKey: "acp_test_provider_\(UUID().uuidString)")
        workspace.providerStore = store
        return workspace
    }

    private func claudeEntry() -> AgentWorkspaceStore.PaneEntry {
        AgentWorkspaceStore.PaneEntry(
            id: 1, presetID: "claude-code", customPreset: nil,
            cwd: NSHomeDirectory(), title: nil, instanceID: nil,
            acpSessionID: nil, startCommand: nil)
    }

    private func opencodeEntry() -> AgentWorkspaceStore.PaneEntry {
        AgentWorkspaceStore.PaneEntry(
            id: 1, presetID: "opencode", customPreset: nil,
            cwd: NSHomeDirectory(), title: nil, instanceID: nil,
            acpSessionID: nil, startCommand: nil)
    }

    func testPresetForInjectsActiveProviderEnvForClaudeCode() {
        let store = ClaudeCodeProviderStore()
        var zaiWithToken = ClaudeCodeProvider.zai
        zaiWithToken.authToken = "test-token-123"
        store.upsert(zaiWithToken)
        store.setActive("zai")

        let workspace = makeWorkspace(store: store)
        let preset = workspace.presetFor(claudeEntry())

        XCTAssertEqual(preset.id, "claude-code")
        XCTAssertEqual(preset.env["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(preset.env["ANTHROPIC_AUTH_TOKEN"], "test-token-123")
        XCTAssertNotNil(preset.env["ANTHROPIC_DEFAULT_OPUS_MODEL"])
    }

    func testPresetForDoesNotInjectForOtherAgents() {
        let store = ClaudeCodeProviderStore()
        var zaiWithToken = ClaudeCodeProvider.zai
        zaiWithToken.authToken = "test-token-123"
        store.upsert(zaiWithToken)
        store.setActive("zai")

        let workspace = makeWorkspace(store: store)
        let preset = workspace.presetFor(opencodeEntry())

        XCTAssertEqual(preset.id, "opencode")
        XCTAssertNil(preset.env["ANTHROPIC_BASE_URL"], "provider env only applies to claude-code")
        XCTAssertNil(preset.env["ANTHROPIC_AUTH_TOKEN"])
    }

    func testPresetForAnthropicActiveLeavesEnvEmpty() {
        let store = ClaudeCodeProviderStore()
        XCTAssertEqual(store.activeID, "anthropic")

        let workspace = makeWorkspace(store: store)
        let preset = workspace.presetFor(claudeEntry())

        XCTAssertEqual(preset.id, "claude-code")
        XCTAssertTrue(preset.env.isEmpty, "Anthropic builtin has no overrides")
    }

    func testPresetForCustomEnvWinsOverProvider() {
        // A custom preset that already sets ANTHROPIC_BASE_URL should not
        // have it overwritten by the active provider — the per-pane env
        // is the explicit override.
        let store = ClaudeCodeProviderStore()
        store.setActive("zai")

        let workspace = makeWorkspace(store: store)
        var customEnv = ACPAgentPreset.claude
        customEnv.env["ANTHROPIC_BASE_URL"] = "https://my-custom-endpoint"
        let entry = AgentWorkspaceStore.PaneEntry(
            id: 1, presetID: "claude-code", customPreset: customEnv,
            cwd: NSHomeDirectory(), title: nil, instanceID: nil,
            acpSessionID: nil, startCommand: nil)
        let preset = workspace.presetFor(entry)

        XCTAssertEqual(preset.env["ANTHROPIC_BASE_URL"], "https://my-custom-endpoint",
                       "custom preset env wins")
        XCTAssertNotNil(preset.env["ANTHROPIC_DEFAULT_OPUS_MODEL"],
                        "provider fills missing slots")
    }
}
