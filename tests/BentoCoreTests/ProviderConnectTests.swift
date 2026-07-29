import XCTest
import ACPHostKit
@testable import BentoCore

/// Scripted executor: each test declares what the machine looks like
/// (binaries present, probe outcomes per call, shell exit codes) and the
/// tests assert the state machine walks the designed path.
private final class ScriptedExecutor: ProviderExecutor, @unchecked Sendable {
    let lock = NSLock()
    var binaries: Set<String> = []
    /// Probe outcomes consumed in order per preset command; last one sticks.
    var probeScript: [ProviderProbeOutcome] = []
    var probeCalls = 0
    /// command prefix → (exit code, output lines). Default success, no output.
    var shellResults: [(prefix: String, status: Int32, lines: [String])] = []
    var ranCommands: [String] = []
    var openedTerminal: [String] = []

    func runShell(_ command: String, onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        lock.lock(); ranCommands.append(command)
        let hit = shellResults.first { command.hasPrefix($0.prefix) }
        lock.unlock()
        for line in hit?.lines ?? [] { onLine(line) }
        return hit?.status ?? 0
    }

    var deepProbes: [ACPAgentPreset] = []

    func probe(_ preset: ACPAgentPreset, deep: Bool) async -> ProviderProbeOutcome {
        lock.lock(); defer { lock.unlock() }
        if deep { deepProbes.append(preset) }
        let outcome = probeCalls < probeScript.count
            ? probeScript[probeCalls] : (probeScript.last ?? .notFound)
        probeCalls += 1
        return outcome
    }

    func binaryFound(_ name: String) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return binaries.contains(name)
    }

    func openURL(_ url: String) {}
    func openInTerminal(_ command: String) {
        lock.lock(); openedTerminal.append(command); lock.unlock()
    }
}

@MainActor
final class ProviderConnectTests: XCTestCase {
    private func makeStore(
        _ executor: ScriptedExecutor,
        providers: [AIProvider] = [.codex],
        onFirst: @escaping @MainActor (AIProvider) -> Void = { _ in }
    ) -> ProviderConnectStore {
        ProviderConnectStore(providers: providers, executor: executor, onFirstConnected: onFirst)
    }

    private func waitUntilIdle(_ store: ProviderConnectStore) async {
        for _ in 0..<200 {
            if store.busyProviderID == nil { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("connect flow never finished")
    }

    // MARK: Entry probe mapping

    func testRefreshMapsProbeOutcomes() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["codex-acp"]
        executor.probeScript = [.ready(model: nil)]
        executor.shellResults = [("codex login status", 0, ["Logged in using ChatGPT"])]
        let store = makeStore(executor)
        await store.refreshAll()
        XCTAssertEqual(store.cards[0].phase, .connected)
        XCTAssertEqual(store.cards[0].identity, "ChatGPT account")

        executor.probeScript = [.authRequired]
        executor.probeCalls = 0
        await store.refresh(store.cards[0])
        XCTAssertEqual(store.cards[0].phase, .needsSignIn)
    }

    func testRefreshWithoutBinaryIsNotInstalled() async {
        let executor = ScriptedExecutor()  // no binaries
        let store = makeStore(executor)
        await store.refreshAll()
        XCTAssertEqual(store.cards[0].phase, .notInstalled)
        XCTAssertEqual(executor.probeCalls, 0, "no probe when the binary is missing")
    }

    // MARK: Full connect flow

    func testConnectInstallsSignsInVerifies() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["node"]  // codex needs Node; missing binary → install
        executor.probeScript = [.authRequired, .ready(model: nil)]
        executor.shellResults = [("codex login status", 0, ["Logged in using ChatGPT"])]
        var promoted: String?
        let store = makeStore(executor) { promoted = $0.id }

        store.connect(store.cards[0])
        await waitUntilIdle(store)

        XCTAssertEqual(store.cards[0].phase, .connected)
        XCTAssertEqual(promoted, "codex")
        XCTAssertTrue(store.cards[0].isDefault)
        // install command ran, then the vendor login, then auth status.
        XCTAssertTrue(executor.ranCommands[0].contains("npm install -g @openai/codex"))
        XCTAssertTrue(executor.ranCommands.contains("codex login"))
        XCTAssertEqual(executor.probeCalls, 2, "probe before sign-in, probe after")
    }

    func testAlreadySignedInSkipsLogin() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["codex-acp", "node"]
        executor.probeScript = [.ready(model: nil)]
        let store = makeStore(executor)
        store.connect(store.cards[0])
        await waitUntilIdle(store)
        XCTAssertEqual(store.cards[0].phase, .connected)
        XCTAssertFalse(executor.ranCommands.contains("codex login"))
    }

    func testInstallFailureIsAttentionWithRetry() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["node"]
        executor.shellResults = [("npm install", 1, ["npm ERR! network"])]
        let store = makeStore(executor)
        store.connect(store.cards[0])
        await waitUntilIdle(store)
        guard case .attention(let issue) = store.cards[0].phase else {
            return XCTFail("expected attention, got \(store.cards[0].phase)")
        }
        XCTAssertEqual(issue.fix, .retryInstall)
        XCTAssertTrue(store.cards[0].log.contains("npm ERR! network"), "truth stays readable")
    }

    func testMissingNodeWithoutBrewIsHonest() async {
        let executor = ScriptedExecutor()  // no node, no brew
        let store = makeStore(executor)
        store.connect(store.cards[0])
        await waitUntilIdle(store)
        guard case .attention(let issue) = store.cards[0].phase else {
            return XCTFail("expected attention")
        }
        XCTAssertEqual(issue.fix, .installNode)
        XCTAssertTrue(executor.ranCommands.isEmpty, "nothing runs without the prerequisite")
    }

    func testPathMismatchSurfacesFixInstall() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["node"]
        executor.probeScript = [.notFound]  // installed per shell, invisible to daemon
        let store = makeStore(executor)
        store.connect(store.cards[0])
        await waitUntilIdle(store)
        guard case .attention(let issue) = store.cards[0].phase else {
            return XCTFail("expected attention")
        }
        XCTAssertEqual(issue.fix, .fixInstall)
    }

    // MARK: BYO (OpenCode)

    func testByoConnectSkipsSignInAndReportsModel() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["brew"]
        executor.probeScript = [.ready(model: "GLM-5.2")]
        let store = makeStore(executor, providers: [.opencode])
        store.connect(store.cards[0])
        await waitUntilIdle(store)
        XCTAssertEqual(store.cards[0].phase, .connected)
        XCTAssertEqual(store.cards[0].identity, "GLM-5.2")
        XCTAssertEqual(executor.ranCommands, ["brew install sst/tap/opencode"],
                       "brew route preferred when brew exists; no login step")
    }

    // MARK: Terminal-style sign-in (Gemini)

    func testTerminalLoginOpensTerminalAndParksOnRetry() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["node", "brew"]
        executor.probeScript = [.authRequired]
        let store = makeStore(executor, providers: [.gemini])
        store.connect(store.cards[0])
        await waitUntilIdle(store)
        guard case .attention(let issue) = store.cards[0].phase else {
            return XCTFail("expected attention")
        }
        XCTAssertEqual(issue.fix, .retryVerify)
        XCTAssertEqual(executor.openedTerminal, ["gemini"])
    }

    // MARK: Serialization + default promotion

    func testOnlyOneFlowAtATimeAndFirstConnectedWins() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["claude-agent-acp", "codex-acp", "node"]
        executor.probeScript = [.ready(model: nil)]
        executor.shellResults = [
            ("claude auth status", 0, [#"{"loggedIn": true, "email": "a@b.c", "subscriptionType": "max"}"#]),
            ("codex login status", 0, ["Logged in using ChatGPT"]),
        ]
        var promotions: [String] = []
        let store = makeStore(executor, providers: [.claude, .codex]) { promotions.append($0.id) }

        store.connect(store.cards[0])
        store.connect(store.cards[1])  // ignored: a flow is in flight
        await waitUntilIdle(store)
        store.connect(store.cards[1])
        await waitUntilIdle(store)

        XCTAssertEqual(promotions, ["claude-code"], "only the first connect promotes")
        XCTAssertTrue(store.cards[0].isDefault)
        XCTAssertFalse(store.cards[1].isDefault)
        XCTAssertEqual(store.cards[0].identity, "a@b.c · Max")
    }

    // MARK: Default promotion discipline

    /// Passive probes must NEVER write the default (a probe racing to green
    /// silently rewrote the user's real setting once) — they only badge the
    /// card matching the app's current default.
    func testPassiveRefreshBadgesButNeverWritesDefault() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["claude-agent-acp", "codex-acp"]
        executor.probeScript = [.ready(model: nil), .ready(model: nil)]
        executor.shellResults = [
            ("claude auth status", 0, [#"{"loggedIn": true, "email": "a@b.c"}"#]),
            ("codex login status", 0, ["Logged in using ChatGPT"]),
        ]
        var promotions: [String] = []
        let store = ProviderConnectStore(
            providers: [.claude, .codex], executor: executor,
            defaultProviderID: { "codex" },
            onFirstConnected: { promotions.append($0.id) })
        await store.refreshAll()

        XCTAssertTrue(promotions.isEmpty, "passive refresh wrote the default")
        XCTAssertFalse(store.cards[0].isDefault)
        XCTAssertTrue(store.cards[1].isDefault, "badge follows the app's setting")
    }

    func testActionConnectNeverStealsExistingDefault() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["claude-agent-acp", "codex-acp", "node"]
        executor.probeScript = [.ready(model: nil)]
        executor.shellResults = [
            ("claude auth status", 0, [#"{"loggedIn": true, "email": "a@b.c"}"#]),
            ("codex login status", 0, ["Logged in using ChatGPT"]),
        ]
        var promotions: [String] = []
        let store = ProviderConnectStore(
            providers: [.claude, .codex], executor: executor,
            defaultProviderID: { "codex" },
            onFirstConnected: { promotions.append($0.id) })
        await store.refreshAll()          // codex badged from the setting
        store.connect(store.cards[0])     // user action on claude
        await waitUntilIdle(store)

        XCTAssertEqual(store.cards[0].phase, .connected)
        XCTAssertTrue(promotions.isEmpty, "claude must not steal codex's default")
        XCTAssertTrue(store.cards[1].isDefault)
    }

    // MARK: API-key providers (Kimi/GLM/DeepSeek — Claude Code harness)

    func testApiKeyConnectParksOnPasteField() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["node"]  // harness missing → install, then park
        let store = makeStore(executor, providers: [.deepseek])
        store.connect(store.cards[0])
        await waitUntilIdle(store)
        XCTAssertEqual(store.cards[0].phase, .needsKey)
        XCTAssertTrue(executor.ranCommands[0].contains("claude-agent-acp"),
                      "installs the harness adapter, not a vendor CLI")
    }

    func testSubmitKeyDeepProbesAndSaves() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["claude-agent-acp", "node"]
        executor.probeScript = [.ready(model: nil)]
        let keys = InMemoryProviderKeyStore()
        let store = ProviderConnectStore(
            providers: [.deepseek], executor: executor, keyStore: keys)
        store.cards[0].phase = .needsKey
        store.submitKey(store.cards[0], key: "sk-test-1234")
        await waitUntilIdle(store)

        XCTAssertEqual(store.cards[0].phase, .connected)
        XCTAssertEqual(store.cards[0].identity, "API key ····1234")
        XCTAssertEqual(keys.key(for: "deepseek-cc"), "sk-test-1234")
        // The deep probe carried the vendor endpoint AND the key.
        XCTAssertEqual(executor.deepProbes.count, 1)
        XCTAssertEqual(executor.deepProbes[0].env["ANTHROPIC_BASE_URL"],
                       "https://api.deepseek.com/anthropic")
        XCTAssertEqual(executor.deepProbes[0].env["ANTHROPIC_AUTH_TOKEN"], "sk-test-1234")
    }

    func testBadKeyIsHonestAndNotSaved() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["claude-agent-acp", "node"]
        executor.probeScript = [.failed("no reply from the model — the key may be invalid")]
        let keys = InMemoryProviderKeyStore()
        let store = ProviderConnectStore(
            providers: [.kimi], executor: executor, keyStore: keys)
        store.cards[0].phase = .needsKey
        store.submitKey(store.cards[0], key: "sk-bad")
        await waitUntilIdle(store)

        guard case .attention(let issue) = store.cards[0].phase else {
            return XCTFail("expected attention, got \(store.cards[0].phase)")
        }
        XCTAssertEqual(issue.fix, .retryKey)
        XCTAssertNil(keys.key(for: "kimi-cc"), "a rejected key must not persist")
        store.fix(store.cards[0])
        XCTAssertEqual(store.cards[0].phase, .needsKey, "fix returns to the paste field")
    }

    func testRefreshWithStoredKeyIsStructuralOnly() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["claude-agent-acp"]
        executor.probeScript = [.ready(model: nil)]
        let keys = InMemoryProviderKeyStore()
        keys.setKey("sk-saved-9999", for: "glm-cc")
        let store = ProviderConnectStore(
            providers: [.glm], executor: executor, keyStore: keys)
        await store.refreshAll()
        XCTAssertEqual(store.cards[0].phase, .connected)
        XCTAssertEqual(store.cards[0].identity, "API key ····9999")
        XCTAssertTrue(executor.deepProbes.isEmpty,
                      "entry probes never burn the key's tokens")
    }

    func testRefreshWithoutKeyParksOnPasteField() async {
        let executor = ScriptedExecutor()
        executor.binaries = ["claude-agent-acp"]
        let store = makeStore(executor, providers: [.kimi])
        await store.refreshAll()
        XCTAssertEqual(store.cards[0].phase, .needsKey)
        XCTAssertEqual(executor.probeCalls, 0, "no probe without a key")
    }

    // MARK: Identity parsing

    func testIdentityParsing() {
        XCTAssertEqual(
            ProviderIdentity.parse(
                providerID: "claude-code",
                output: #"{"loggedIn":true,"email":"x@y.z","subscriptionType":"max"}"#),
            "x@y.z · Max")
        XCTAssertNil(
            ProviderIdentity.parse(providerID: "claude-code", output: #"{"loggedIn":false}"#))
        XCTAssertEqual(
            ProviderIdentity.parse(providerID: "codex", output: "Logged in using ChatGPT"),
            "ChatGPT account")
        XCTAssertNil(ProviderIdentity.parse(providerID: "codex", output: "Not logged in"))
    }
}
