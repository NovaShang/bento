import Foundation
import BentoTerminalCore
import SwiftUI
import UIKit

/// Identity of a single live session = (host, tmux session name).
/// `tmuxSessionName` is the empty string for a "no tmux" raw-shell session;
/// at most one such session per host.
struct SessionKey: Hashable {
    let hostID: UUID
    let tmuxSessionName: String
}

/// Central registry of live `TerminalViewModel` instances.
///
/// One VM owns one SSH connection. A host can have multiple concurrent VMs —
/// one per attached tmux session — and each is fully independent. Listing
/// tmux sessions on a host happens through a *separate* short-lived SSH (see
/// `listTmuxSessions(host:)`) so discovery is decoupled from any attached
/// control channel.
@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    struct SessionEntry: Identifiable {
        var id: SessionKey { key }
        let key: SessionKey
        let host: Host
        let viewModel: TerminalViewModel
        var lastActiveAt: Date
    }

    @Published private(set) var activeSessions: [SessionEntry] = []

    /// Driven by `NavigationStack(path:)` in `BentoApp`.
    @Published var navigationPath: [HostNavigation] = []

    /// Transient toast text for the host list (e.g. "Disconnected oldest session to free a slot").
    @Published var evictionNotice: String? = nil

    let maxSessions: Int
    private let liveActivity = AggregateLiveActivityController()

    /// Non-published cache so SwiftUI `body` can resolve the VM synchronously
    /// without triggering "modifying state during view update". Registration
    /// into the published `activeSessions` is deferred to the next runloop.
    private var cache: [SessionKey: TerminalViewModel] = [:]

    init(maxSessions: Int = 5) {
        self.maxSessions = maxSessions
    }

    // MARK: - Lookup

    /// Returns the cached `TerminalViewModel` for `key` if one exists.
    /// Side-effect free.
    func existingViewModel(for key: SessionKey) -> TerminalViewModel? {
        cache[key]
    }

    /// All active sessions for a given host (used to mark "Active" rows in
    /// the picker and to handle host-level operations).
    func sessions(forHostID hostID: UUID) -> [SessionEntry] {
        activeSessions.filter { $0.key.hostID == hostID }
    }

    /// Returns the cached `TerminalViewModel` for `(host, tmuxSessionName)`,
    /// or creates and registers a new one. Bumps `lastActiveAt`. May evict
    /// the oldest entry if registering a new session would exceed
    /// `maxSessions`.
    ///
    /// Safe to call from SwiftUI `body`: mutations to `@Published
    /// activeSessions` are deferred to the next runloop.
    func viewModel(for host: Host, tmuxSessionName: String) -> TerminalViewModel {
        let key = SessionKey(hostID: host.id, tmuxSessionName: tmuxSessionName)
        if let existing = cache[key] {
            Task { @MainActor in self.touch(key: key) }
            return existing
        }

        // Inject the iOS transport (SSH/relay) + platform services. The VM
        // itself is platform-agnostic and lives in BentoTerminalCore.
        let env = TerminalEnvironment(
            idealTerminalSize: {
                let screen = UIScreen.main.bounds
                let font = STTheme.terminalFont
                let cell = NSString(string: "M").size(withAttributes: [.font: font])
                let availH = screen.height - 110
                return (max(Int(screen.width / cell.width), 40),
                        max(Int(availH / cell.height), 20))
            },
            loadKeychainPassword: { key in try? KeychainService.shared.loadPassword(for: key) },
            onAwaitingTriggered: { HapticService.shared.awaitingTriggered() },
            onSessionUpdate: { [weak self] hostID, name, awaiting, prompt in
                self?.sessionDidUpdate(hostID: hostID, tmuxSessionName: name,
                                       awaitingPanes: awaiting, latestPrompt: prompt)
            }
        )
        // Backend seam: a paired Mac (relay host) is ACP-backed — the daemon
        // hosts the agents, panes are chat, no SSH. Direct-TCP SSH hosts are
        // parked until the terminal pane returns (hybrid workbench P1); the
        // VM renders an honest error instead of a dead shell.
        let vm: TerminalViewModel
        if let store = SessionManager.acpStore(for: host) {
            vm = TerminalViewModel(host: host, transport: NullTransport(),
                                   environment: env, workspace: store)
        } else {
            vm = TerminalViewModel(host: host, transport: NullTransport(), environment: env)
            vm.unsupportedReason = "Direct SSH hosts aren't supported in this build. Pair this device with a Mac running Bento instead."
        }
        cache[key] = vm

        Task { @MainActor in
            self.evictIfNeeded(toFitNew: 1)
            if !self.activeSessions.contains(where: { $0.key == key }) {
                self.activeSessions.append(
                    SessionEntry(
                        key: key,
                        host: host,
                        viewModel: vm,
                        lastActiveAt: Date()
                    )
                )
            }
        }
        return vm
    }

    func touch(key: SessionKey) {
        guard let idx = activeSessions.firstIndex(where: { $0.key == key }) else { return }
        activeSessions[idx].lastActiveAt = Date()
    }

    // MARK: - Disconnect

    func disconnect(key: SessionKey) {
        if let vm = cache[key] {
            vm.disconnect()
        }
        cache.removeValue(forKey: key)
        activeSessions.removeAll { $0.key == key }
        liveActivity.sync(sessions: activeSessions)
    }

    func disconnectAll() {
        for vm in cache.values { vm.disconnect() }
        cache.removeAll()
        activeSessions.removeAll()
        liveActivity.sync(sessions: activeSessions)
    }

    func handleHostDeleted(_ host: Host) {
        for entry in activeSessions where entry.key.hostID == host.id {
            disconnect(key: entry.key)
        }
    }

    // MARK: - Scene phase

    /// Background-grace task: keeps the process (and thus the live SSH/relay
    /// connection) running for a short window after backgrounding, so a quick
    /// app switch doesn't drop the connection and force a reconnect on return.
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    /// Whether the grace ran out and we actually suspended the sessions. If we
    /// return to foreground before this flips, the connection is still live and
    /// no reconnect is needed.
    private var didSuspendInBackground = false

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            beginBackgroundGrace()
            liveActivity.sync(sessions: activeSessions)
        case .active:
            let reconnect = endBackgroundGrace()
            if reconnect {
                for entry in activeSessions {
                    Task { await entry.viewModel.resumeFromBackground() }
                }
            }
            liveActivity.sync(sessions: activeSessions)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Ask iOS for extra background time and DEFER the suspend until it runs
    /// out. iOS grants ~30s; within it the run loop keeps ticking so the WS /
    /// SSH connection and its keepalive pings stay alive. If iOS grants nothing
    /// we suspend immediately (the old behavior).
    private func beginBackgroundGrace() {
        didSuspendInBackground = false
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "bento.keepalive") { [weak self] in
            // Time's up — suspend so the next foreground reconnects cleanly.
            self?.suspendNow()
        }
        if bgTask == .invalid { suspendNow() }
    }

    /// Suspend every session now (grace expired or never granted) and release
    /// the background task. Idempotent.
    private func suspendNow() {
        guard !didSuspendInBackground else { return }
        didSuspendInBackground = true
        for entry in activeSessions { entry.viewModel.suspendForBackground() }
        endBgTask()
    }

    /// Called on foreground. Returns whether the sessions were suspended while
    /// backgrounded (→ caller should reconnect). If we returned within the
    /// grace window the connection is still live, so this returns false.
    @discardableResult
    private func endBackgroundGrace() -> Bool {
        let suspended = didSuspendInBackground
        endBgTask()
        didSuspendInBackground = false
        return suspended
    }

    private func endBgTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - State fan-in

    /// Called by `TerminalViewModel` whenever its phase or pane states change.
    /// Identifies the entry by hostID + the VM's current tmux session name.
    func sessionDidUpdate(hostID: UUID, tmuxSessionName: String, awaitingPanes: Int, latestPrompt: String) {
        let key = SessionKey(hostID: hostID, tmuxSessionName: tmuxSessionName)
        guard activeSessions.contains(where: { $0.key == key }) else { return }
        liveActivity.sync(
            sessions: activeSessions,
            spotlightKey: key,
            spotlightPrompt: latestPrompt
        )
    }

    // MARK: - LRU eviction

    private func evictIfNeeded(toFitNew n: Int) {
        while activeSessions.count + n > maxSessions {
            guard let victim = pickEvictionVictim() else { return }
            victim.viewModel.disconnect()
            cache.removeValue(forKey: victim.key)
            activeSessions.removeAll { $0.key == victim.key }
            let label = victim.key.tmuxSessionName.isEmpty
                ? victim.host.displayName
                : "\(victim.host.displayName) · \(victim.key.tmuxSessionName)"
            evictionNotice = "Disconnected \(label) to free a session slot"
        }
    }

    /// LRU choice prefers .ended → .suspended → least-recently-used active.
    private func pickEvictionVictim() -> SessionEntry? {
        let ended = activeSessions.filter { $0.viewModel.phase == .ended }
        if let oldest = ended.min(by: { $0.lastActiveAt < $1.lastActiveAt }) { return oldest }

        let suspended = activeSessions.filter { $0.viewModel.phase == .suspended }
        if let oldest = suspended.min(by: { $0.lastActiveAt < $1.lastActiveAt }) { return oldest }

        return activeSessions.min(by: { $0.lastActiveAt < $1.lastActiveAt })
    }
}

extension SessionManager {
    /// The ACP workspace store for a relay host: launcher wired to the
    /// daemon's sealed relay channel, device key from the Keychain. nil for
    /// SSH hosts (terminal path) or when the key is missing.
    static func acpStore(for host: Host) -> AgentWorkspaceStore? {
        guard case .relay(let daemonID, let fingerprint, let deviceID) = host.transport,
              case .privateKey(let keyLabel) = host.authMethod,
              let deviceKey = try? KeychainService.shared.loadPrivateKey(label: keyLabel)
        else { return nil }
        return AgentWorkspaceStore.relayStore(
            daemonID: daemonID,
            deviceID: deviceID,
            hostKeyFingerprint: fingerprint,
            devicePrivateKey: deviceKey,
            relayBaseURL: RelayPairingService.relayBaseURLString)
    }
}

/// Session discovery for the picker. Paired (relay) hosts read the workspace
/// store's tree (synced from the daemon's statekv) — no shell, no SSH.
/// Direct-SSH hosts are parked until the terminal pane returns (hybrid
/// workbench P1) and answer with an honest error.
@MainActor
final class TmuxLister: ObservableObject {
    @Published private(set) var sessions: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    /// Dismissing the error alert clears the error so it doesn't re-present.
    func clearError() { error = nil }

    private let host: Host

    init(host: Host) {
        self.host = host
    }

    func refresh() async {
        guard let store = SessionManager.acpStore(for: host) else {
            sessions = []
            error = "Direct SSH hosts aren't supported in this build. Pair this device with a Mac running Bento instead."
            return
        }
        isLoading = true
        error = nil
        let reachable = await store.syncWithDaemon()
        sessions = store.sessionList.map(\.name)
        if !reachable && sessions.isEmpty { error = "Failed to reach the Mac" }
        isLoading = false
    }
}
