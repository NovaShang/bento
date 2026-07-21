import Foundation
import BentoCore
import SwiftUI
import UIKit

/// Identity of a single live session = (host, session name).
struct SessionKey: Hashable {
    let hostID: UUID
    let workspaceName: String
}

/// Central registry of live `WorkspaceViewModel` instances.
///
/// One VM owns one connection. A host can have multiple concurrent VMs —
/// one per attached workspace session — and each is fully independent. Session
/// discovery reads the workspace store (see `SessionLister`), decoupled from
/// any attached control channel.
@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    struct WorkspaceEntry: Identifiable {
        var id: SessionKey { key }
        let key: SessionKey
        let host: Host
        let viewModel: WorkspaceViewModel
        var lastActiveAt: Date
    }

    @Published private(set) var activeSessions: [WorkspaceEntry] = []

    /// Driven by `NavigationStack(path:)` in `BentoApp`.
    @Published var navigationPath: [HostNavigation] = []

    /// Transient toast text for the host list (e.g. "Disconnected oldest session to free a slot").
    @Published var evictionNotice: String? = nil

    let maxSessions: Int
    private let liveActivity = AggregateLiveActivityController()

    /// Non-published cache so SwiftUI `body` can resolve the VM synchronously
    /// without triggering "modifying state during view update". Registration
    /// into the published `activeSessions` is deferred to the next runloop.
    private var cache: [SessionKey: WorkspaceViewModel] = [:]

    /// Injectable for tests: how a host resolves to its workspace store.
    var storeProvider: (Host) -> AgentWorkspaceStore? = { SessionManager.acpStore(for: $0) }

    init(maxSessions: Int = 5) {
        self.maxSessions = maxSessions
    }

    // MARK: - Lookup

    /// Returns the cached `WorkspaceViewModel` for `key` if one exists.
    /// Side-effect free.
    func existingViewModel(for key: SessionKey) -> WorkspaceViewModel? {
        cache[key]
    }

    /// All active sessions for a given host (used to mark "Active" rows in
    /// the picker and to handle host-level operations).
    func sessions(forHostID hostID: UUID) -> [WorkspaceEntry] {
        activeSessions.filter { $0.key.hostID == hostID }
    }

    /// Returns the cached `WorkspaceViewModel` for `(host, workspaceName)`,
    /// or creates and registers a new one. Bumps `lastActiveAt`. May evict
    /// the oldest entry if registering a new session would exceed
    /// `maxSessions`. nil when the host has no paired daemon (no device key).
    ///
    /// Safe to call from SwiftUI `body`: mutations to `@Published
    /// activeSessions` are deferred to the next runloop.
    func viewModel(for host: Host, workspaceName: String) -> WorkspaceViewModel? {
        let key = SessionKey(hostID: host.id, workspaceName: workspaceName)
        if let existing = cache[key] {
            Task { @MainActor in self.touch(key: key) }
            return existing
        }

        guard let store = storeProvider(host) else { return nil }
        let env = WorkspaceEnvironment(
            onAwaitingTriggered: { HapticService.shared.awaitingTriggered() },
            onSessionUpdate: { [weak self] hostID, name, awaiting, prompt in
                self?.sessionDidUpdate(hostID: hostID, workspaceName: name,
                                       awaitingPanes: awaiting, latestPrompt: prompt)
            }
        )
        let vm = WorkspaceViewModel(host: host, workspace: store, environment: env)
        cache[key] = vm

        Task { @MainActor in
            self.evictIfNeeded(toFitNew: 1)
            if !self.activeSessions.contains(where: { $0.key == key }) {
                self.activeSessions.append(
                    WorkspaceEntry(
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

    /// Background-grace task: keeps the process (and thus the live relay
    /// connections) running for a short window after backgrounding, so a
    /// quick app switch doesn't drop them and force a re-sync on return.
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
    /// out. iOS grants ~30s; within it the run loop keeps ticking so the
    /// relay WebSocket and its keepalive pings stay alive. If iOS grants
    /// nothing we suspend immediately.
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

    /// Called by `WorkspaceViewModel` whenever its phase or pane states change.
    /// Identifies the entry by hostID + the VM's current session name.
    func sessionDidUpdate(hostID: UUID, workspaceName: String, awaitingPanes: Int, latestPrompt: String) {
        let key = SessionKey(hostID: hostID, workspaceName: workspaceName)
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
            let label = victim.key.workspaceName.isEmpty
                ? victim.host.displayName
                : "\(victim.host.displayName) · \(victim.key.workspaceName)"
            evictionNotice = "Disconnected \(label) to free a session slot"
        }
    }

    /// LRU choice prefers .ended → .suspended → least-recently-used active.
    private func pickEvictionVictim() -> WorkspaceEntry? {
        let ended = activeSessions.filter { $0.viewModel.phase == .ended }
        if let oldest = ended.min(by: { $0.lastActiveAt < $1.lastActiveAt }) { return oldest }

        let suspended = activeSessions.filter { $0.viewModel.phase == .suspended }
        if let oldest = suspended.min(by: { $0.lastActiveAt < $1.lastActiveAt }) { return oldest }

        return activeSessions.min(by: { $0.lastActiveAt < $1.lastActiveAt })
    }
}

extension SessionManager {
    /// The ACP workspace store for a paired host: launcher wired to the
    /// daemon's sealed relay channel, device key from the Keychain. nil when
    /// the key is missing.
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

/// Session discovery for the picker: reads the workspace store's tree,
/// synced from the paired daemon's statekv.
@MainActor
final class SessionLister: ObservableObject {
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
            error = "This device isn't paired with that Mac anymore. Pair again from the Mac's menu bar."
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
