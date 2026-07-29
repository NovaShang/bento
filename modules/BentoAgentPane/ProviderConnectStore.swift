import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import Foundation

// The "Connect your AI" engine: per-provider state machines orchestrated by
// one store. The store owns the flow (install → sign in → verify → green);
// the ProviderExecutor owns the mechanics (shell, ACP probe, browser). v1
// wires a local Process-based executor (macOS); the protocol deliberately
// never assumes local execution so a daemon-RPC executor can slot in for
// iOS-driven and Linux-host connects without touching this file.

// MARK: - Probe

/// What the verify-probe observed. The probe is the ONLY source of a green
/// check: it spawns the provider's ACP adapter exactly the way a pane would
/// (daemon-visible PATH), runs initialize + session/new, and reads the truth.
/// (`authMethods` is NOT a signal — Claude advertises [] when signed in,
/// codex lists methods even when signed in. Validated 2026-07-22.)
public enum ProviderProbeOutcome: Sendable, Equatable {
    /// session/new returned a real session. `model` is the session's current
    /// model id when advertised — the honest "what it runs on" chip (the BYO
    /// card's identity line).
    case ready(model: String?)
    /// JSON-RPC -32000: installed and speaking ACP, but not signed in.
    case authRequired
    /// The adapter binary doesn't resolve in daemon-visible dirs.
    case notFound
    case failed(String)
}

// MARK: - Executor

/// The mechanics behind Connect. Implementations: LocalProviderExecutor
/// (macOS, Process — v1), and eventually a daemon-RPC executor (the designed
/// probe/install/login ops) for phone-driven and headless-host connects.
public protocol ProviderExecutor: Sendable {
    /// Run a command through a login shell, streaming combined output lines.
    /// Returns the exit code. Honors task cancellation by killing the child.
    func runShell(_ command: String, onLine: @escaping @Sendable (String) -> Void) async -> Int32
    /// Spawn `preset` the way the daemon would and drive the ACP handshake.
    /// `deep` additionally runs one tiny prompt turn — the only honest check
    /// for API-key providers, where session/new succeeds even with a bad key
    /// (validated 2026-07-22); a bad key hangs in SDK retries, so deep probes
    /// enforce a deadline.
    func probe(_ preset: ACPAgentPreset, deep: Bool) async -> ProviderProbeOutcome
    /// Whether a binary resolves in daemon-visible dirs.
    func binaryFound(_ name: String) async -> Bool
    /// Open a URL where the human is (Mac: local browser; future phone
    /// executor: the phone's browser — the keystone of remote connect).
    func openURL(_ url: String)
    /// Escape hatch for `.terminal`-style logins: run the vendor's
    /// interactive sign-in in a visible terminal window.
    func openInTerminal(_ command: String)
}

// MARK: - Phases

public enum ProviderPhase: Equatable {
    case unknown
    case checking
    case notInstalled
    /// Installed (probe spoke ACP) but the vendor account isn't signed in.
    case needsSignIn
    /// `.apiKey` provider: harness installed, waiting for the pasted key.
    case needsKey
    case installing
    case signingIn
    case verifying
    case connected
    case attention(ProviderIssue)

    public var isConnected: Bool { self == .connected }
    public var isBusy: Bool {
        switch self {
        case .installing, .signingIn, .verifying, .checking: return true
        default: return false
        }
    }
}

/// Every failure is one human sentence plus the button that fixes it —
/// never a bare error string (the "each error is a lesson" rule).
public struct ProviderIssue: Equatable {
    public enum Fix: Equatable {
        case retryInstall
        case retrySignIn
        case retryVerify
        /// Back to the paste field — the submitted key didn't work.
        case retryKey
        /// Binary landed outside daemon-visible dirs (e.g. nvm npm prefix).
        case fixInstall
        case installNode
    }
    public var message: String
    public var fix: Fix

    public init(message: String, fix: Fix) {
        self.message = message
        self.fix = fix
    }
}

// MARK: - Card model

/// One card's observable state. Views bind to this; only the store mutates it.
@MainActor
public final class ProviderCardModel: ObservableObject, Identifiable {
    public let provider: AIProvider
    @Published public package(set) var phase: ProviderPhase = .unknown
    /// "styleshang@gmail.com · Max", "ChatGPT account", "GLM-5.2 via Z.AI"…
    @Published public internal(set) var identity: String?
    /// Tail line of the running install, for the progress row.
    @Published public internal(set) var progressLine: String?
    /// Full raw output, behind "Show details" — the truth stays readable.
    @Published public internal(set) var log: String = ""
    /// First http(s) URL seen during sign-in (the "Nothing opened?" fallback).
    @Published public internal(set) var signInURL: String?
    @Published public internal(set) var isDefault: Bool = false

    public nonisolated var id: String { provider.id }

    nonisolated init(provider: AIProvider) {
        self.provider = provider
    }

    func appendLog(_ line: String) {
        log += line + "\n"
        progressLine = line.trimmingCharacters(in: .whitespaces)
        if signInURL == nil, phase == .signingIn || phase == .installing,
           let url = Self.firstURL(in: line) {
            signInURL = url
        }
    }

    static func firstURL(in line: String) -> String? {
        guard let range = line.range(of: #"https?://\S+"#, options: .regularExpression)
        else { return nil }
        return String(line[range])
    }
}

// MARK: - Store

@MainActor
public final class ProviderConnectStore: ObservableObject {
    public let cards: [ProviderCardModel]
    /// One connect flow at a time — browser sign-ins must not interleave.
    @Published public private(set) var busyProviderID: String?

    private let executor: ProviderExecutor
    /// `.apiKey` providers' pasted keys (Keychain in the app, fake in tests).
    private let keyStore: ProviderKeyStoring
    /// The app's current default agent id — used to BADGE the matching card
    /// on passive refresh. Passive probes never write the default (a probe
    /// racing to green must not silently rewrite the user's setting; learned
    /// the hard way when debug wizards polluted the real UserDefaults).
    private let defaultProviderID: @MainActor () -> String?
    /// Fired when a USER ACTION makes a provider the default: the first
    /// action-connected provider when none is claimed, or a card click.
    private let onFirstConnected: @MainActor (AIProvider) -> Void
    private var flowTask: Task<Void, Never>?

    public var anyConnected: Bool { cards.contains { $0.phase.isConnected } }
    public var firstScreenCards: [ProviderCardModel] { cards.filter { $0.provider.firstScreen } }
    public var moreCards: [ProviderCardModel] { cards.filter { !$0.provider.firstScreen } }

    public nonisolated init(
        providers: [AIProvider] = AIProvider.catalog,
        executor: ProviderExecutor,
        keyStore: ProviderKeyStoring = InMemoryProviderKeyStore(),
        defaultProviderID: @escaping @MainActor () -> String? = { nil },
        onFirstConnected: @escaping @MainActor (AIProvider) -> Void = { _ in }
    ) {
        self.cards = providers.map(ProviderCardModel.init)
        self.executor = executor
        self.keyStore = keyStore
        self.defaultProviderID = defaultProviderID
        self.onFirstConnected = onFirstConnected
    }

    // MARK: Entry probe

    /// Silent probe of every provider on step entry: already-installed,
    /// already-signed-in setups flip green with zero user action.
    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for card in cards where !card.phase.isBusy {
                group.addTask { @MainActor in await self.refresh(card) }
            }
        }
    }

    public func refresh(_ card: ProviderCardModel) async {
        card.phase = .checking
        guard await executor.binaryFound(card.provider.acpPreset.command) else {
            card.phase = .notInstalled
            return
        }
        if card.provider.kind == .apiKey {
            // Key present → structural probe only (the key was prompt-verified
            // when it was pasted; re-burning tokens on every entry would be
            // rude). No key → the paste field.
            guard let key = keyStore.key(for: card.provider.id) else {
                card.phase = .needsKey
                return
            }
            await applyProbe(
                to: card,
                outcome: executor.probe(card.provider.acpPreset(withKey: key), deep: false),
                promoteOnConnect: false)
            return
        }
        await applyProbe(
            to: card,
            outcome: executor.probe(card.provider.acpPreset, deep: false),
            promoteOnConnect: false)
    }

    // MARK: Connect flow

    public func connect(_ card: ProviderCardModel) {
        guard busyProviderID == nil else { return }
        busyProviderID = card.provider.id
        card.log = ""
        card.signInURL = nil
        flowTask = Task { [weak self] in
            await self?.runConnectFlow(card)
            await MainActor.run { self?.busyProviderID = nil }
        }
    }

    public func cancel() {
        flowTask?.cancel()
        flowTask = nil
        if let id = busyProviderID, let card = cards.first(where: { $0.id == id }) {
            Task { await refresh(card) }
        }
        busyProviderID = nil
    }

    /// "Nothing opened?" fallback — reopen the captured sign-in URL where
    /// the human is (this executor's side of the keystone rule).
    public func openSignInURL(_ url: String) {
        executor.openURL(url)
    }

    /// Explicitly promote a connected provider to the default agent (the
    /// card's ⋯ menu). Moves the "Default" badge and rewrites the setting.
    public func makeDefault(_ card: ProviderCardModel) {
        guard card.phase.isConnected else { return }
        for other in cards { other.isDefault = false }
        card.isDefault = true
        onFirstConnected(card.provider)
    }

    /// Resolve an attention card's fix button back into the right flow step.
    public func fix(_ card: ProviderCardModel) {
        guard case .attention(let issue) = card.phase else { return }
        switch issue.fix {
        case .retryKey:
            // Straight back to the paste field — no flow to run yet.
            card.phase = .needsKey
        case .retryInstall, .fixInstall, .installNode:
            connect(card)
        case .retrySignIn:
            guard busyProviderID == nil else { return }
            busyProviderID = card.provider.id
            flowTask = Task { [weak self] in
                await self?.runSignIn(card)
                await MainActor.run { self?.busyProviderID = nil }
            }
        case .retryVerify:
            guard busyProviderID == nil else { return }
            busyProviderID = card.provider.id
            flowTask = Task { [weak self] in
                await self?.runVerify(card)
                await MainActor.run { self?.busyProviderID = nil }
            }
        }
    }

    private func runConnectFlow(_ card: ProviderCardModel) async {
        // 1. Install when missing (one button = the whole chain, Node included).
        if !(await executor.binaryFound(card.provider.acpPreset.command)) {
            guard await runInstall(card) else { return }
        }
        // 2. API-key providers park on the paste field (or re-verify a
        //    stored key); everyone else probes and signs in as needed.
        if card.provider.kind == .apiKey {
            if let key = keyStore.key(for: card.provider.id) {
                await runKeyVerify(card, key: key)
            } else {
                card.phase = .needsKey
            }
            return
        }
        await runVerify(card, signInOnAuthRequired: true)
    }

    // MARK: API-key flow

    /// The paste-field submit: one tiny prompt turn against the vendor's
    /// endpoint proves the key (session/new alone can't), then the key is
    /// saved. A bad key hangs in harness retries, so the executor's deep
    /// probe carries a deadline and we translate that into an honest message.
    public func submitKey(_ card: ProviderCardModel, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, busyProviderID == nil else { return }
        busyProviderID = card.provider.id
        flowTask = Task { [weak self] in
            await self?.runKeyVerify(card, key: trimmed)
            await MainActor.run { self?.busyProviderID = nil }
        }
    }

    private func runKeyVerify(_ card: ProviderCardModel, key: String) async {
        card.phase = .verifying
        let outcome = await executor.probe(card.provider.acpPreset(withKey: key), deep: true)
        if Task.isCancelled { return }
        switch outcome {
        case .ready:
            keyStore.setKey(key, for: card.provider.id)
            card.identity = AIProvider.maskedKey(key)
            card.phase = .connected
            promoteIfUnclaimed(card)
        case .notFound:
            card.phase = .attention(ProviderIssue(
                message: "Installed, but Bento can't reach it. Reinstalling usually fixes this.",
                fix: .fixInstall))
        case .authRequired, .failed:
            keyStore.deleteKey(for: card.provider.id)
            card.phase = .attention(ProviderIssue(
                message: "The key didn't work — check it and paste it again.",
                fix: .retryKey))
        }
    }

    private func runInstall(_ card: ProviderCardModel) async -> Bool {
        card.phase = .installing
        var commands = card.provider.installCommands
        if let brew = card.provider.brewInstallCommand, await executor.binaryFound("brew") {
            commands = [brew]
        }
        if card.provider.requiresNode, !(await executor.binaryFound("node")) {
            if await executor.binaryFound("brew") {
                commands.insert("brew install node", at: 0)
            } else {
                card.phase = .attention(ProviderIssue(
                    message: "\(card.provider.name) needs Node.js, which isn't installed. Install it from nodejs.org, then try again.",
                    fix: .installNode))
                return false
            }
        }
        for command in commands {
            card.appendLog("$ \(command)")
            let status = await executor.runShell(command) { [weak card] line in
                Task { @MainActor in card?.appendLog(line) }
            }
            if Task.isCancelled { return false }
            if status != 0 {
                card.phase = .attention(ProviderIssue(
                    message: "Install didn't finish (exit \(status)).",
                    fix: .retryInstall))
                return false
            }
        }
        return true
    }

    private func runSignIn(_ card: ProviderCardModel) async {
        switch card.provider.login {
        case .cli(let command):
            card.phase = .signingIn
            card.appendLog("$ \(command)")
            let status = await executor.runShell(command) { [weak card] line in
                Task { @MainActor in card?.appendLog(line) }
            }
            if Task.isCancelled { return }
            if status != 0 {
                card.phase = .attention(ProviderIssue(
                    message: "Sign-in didn't finish — the browser window may have been closed.",
                    fix: .retrySignIn))
                return
            }
            await runVerify(card)
        case .terminal(let command):
            // Interactive-only vendors: honest escape hatch. A terminal opens
            // for this one step; Retry re-probes when the user is done.
            card.phase = .attention(ProviderIssue(
                message: "\(card.provider.name) signs in through its own screen — finish there, then retry.",
                fix: .retryVerify))
            executor.openInTerminal(command)
        case .none:
            await runVerify(card)
        }
    }

    private func runVerify(_ card: ProviderCardModel, signInOnAuthRequired: Bool = false) async {
        card.phase = .verifying
        let outcome = await executor.probe(card.provider.acpPreset, deep: false)
        if Task.isCancelled { return }
        if case .authRequired = outcome, signInOnAuthRequired {
            await runSignIn(card)
            return
        }
        // runVerify only runs inside user-initiated flows (Connect / fixes).
        await applyProbe(to: card, outcome: outcome, promoteOnConnect: true)
    }

    /// Maps probe truth to card state. Green comes ONLY from `.ready`.
    /// `promoteOnConnect`: user-action flows may claim the default; passive
    /// refresh only badges the card matching the app's current setting.
    private func applyProbe(
        to card: ProviderCardModel, outcome: ProviderProbeOutcome, promoteOnConnect: Bool
    ) async {
        switch outcome {
        case .ready(let model):
            card.identity = await resolveIdentity(card, probedModel: model)
            card.phase = .connected
            if promoteOnConnect {
                promoteIfUnclaimed(card)
            } else if card.provider.id == defaultProviderID()
                        || card.provider.seedCommand == defaultProviderID() {
                card.isDefault = true
            }
        case .authRequired:
            card.phase = .needsSignIn
        case .notFound:
            // Installed per the login shell but invisible to the daemon —
            // the PATH-mismatch rung. Reinstalling routes to visible dirs.
            card.phase = .attention(ProviderIssue(
                message: "Installed, but Bento can't reach it. Reinstalling usually fixes this.",
                fix: .fixInstall))
        case .failed(let reason):
            card.phase = .attention(ProviderIssue(
                message: "Signed in, but the agent couldn't start a session (\(reason)).",
                fix: .retryVerify))
        }
    }

    private func resolveIdentity(_ card: ProviderCardModel, probedModel: String?) async -> String? {
        if card.provider.kind == .apiKey {
            return keyStore.key(for: card.provider.id).map(AIProvider.maskedKey)
        }
        if let statusCommand = card.provider.authStatusCommand {
            var output = ""
            let status = await executor.runShell(statusCommand) { line in
                Task { @MainActor in output += line + "\n" }
            }
            await Task.yield()
            if status == 0,
               let identity = ProviderIdentity.parse(providerID: card.provider.id, output: output) {
                return identity
            }
        }
        // BYO cards report what they actually run on (probe's model id).
        if card.provider.kind == .byo, let model = probedModel {
            return model
        }
        return nil
    }

    /// A user action connected this provider: claim the default slot iff no
    /// card holds it yet (never steal an existing default).
    private func promoteIfUnclaimed(_ card: ProviderCardModel) {
        guard !cards.contains(where: { $0.isDefault }) else { return }
        card.isDefault = true
        onFirstConnected(card.provider)
    }
}
