#if canImport(UIKit)
import Foundation
import BentoFoundation
import BentoUI
import BentoWorkbench
import BentoVoiceKit
import BentoFilePreviewKit
import BentoLink
import SwiftUI
import UIKit

/// Identity of a single live session = (host, session name).
public struct SessionKey: Hashable {
    public let hostID: UUID
    public let workspaceName: String
    public init(hostID: UUID, workspaceName: String) {
        self.hostID = hostID
        self.workspaceName = workspaceName
    }
}

/// Central registry of live `WorkspaceViewModel` instances.
///
/// One VM owns one connection. A host can have multiple concurrent VMs —
/// one per attached workspace session — and each is fully independent. Session
/// discovery reads the workspace store (see `SessionLister`), decoupled from
/// any attached control channel.
@MainActor
public final class SessionManager: ObservableObject {
    public static let shared = SessionManager()

    public struct WorkspaceEntry: Identifiable {
        public var id: SessionKey { key }
        public let key: SessionKey
        public let host: Host
        public let viewModel: WorkspaceViewModel
        public var lastActiveAt: Date
    }

    @Published public private(set) var activeSessions: [WorkspaceEntry] = []

    /// Driven by `NavigationStack(path:)` in `BentoApp`.
    @Published public var navigationPath: [HostNavigation] = []

    /// Transient toast text for the host list (e.g. "Disconnected oldest session to free a slot").
    @Published public var evictionNotice: String? = nil

    public let maxSessions: Int
    private let liveActivity = AggregateLiveActivityController()

    /// Non-published cache so SwiftUI `body` can resolve the VM synchronously
    /// without triggering "modifying state during view update". Registration
    /// into the published `activeSessions` is deferred to the next runloop.
    private var cache: [SessionKey: WorkspaceViewModel] = [:]

    /// How a host resolves to its workspace store. The generic shell defaults
    /// to "no store"; each app's composition root installs the real provider
    /// (product A: `AcpPaneModule`-installed relay store; product B: the tmux
    /// store). Also the test seam.
    public var storeProvider: (Host) -> AgentWorkspaceStore? = { _ in nil }

    public init(maxSessions: Int = 5) {
        self.maxSessions = maxSessions
    }

    // MARK: - Lookup

    /// Returns the cached `WorkspaceViewModel` for `key` if one exists.
    /// Side-effect free.
    public func existingViewModel(for key: SessionKey) -> WorkspaceViewModel? {
        cache[key]
    }

    /// All active sessions for a given host (used to mark "Active" rows in
    /// the picker and to handle host-level operations).
    public func sessions(forHostID hostID: UUID) -> [WorkspaceEntry] {
        activeSessions.filter { $0.key.hostID == hostID }
    }

    /// Returns the cached `WorkspaceViewModel` for `(host, workspaceName)`,
    /// or creates and registers a new one. Bumps `lastActiveAt`. May evict
    /// the oldest entry if registering a new session would exceed
    /// `maxSessions`. nil when the host has no paired daemon (no device key).
    ///
    /// Safe to call from SwiftUI `body`: mutations to `@Published
    /// activeSessions` are deferred to the next runloop.
    public func viewModel(for host: Host, workspaceName: String) -> WorkspaceViewModel? {
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

    public func touch(key: SessionKey) {
        guard let idx = activeSessions.firstIndex(where: { $0.key == key }) else { return }
        activeSessions[idx].lastActiveAt = Date()
    }

    // MARK: - Disconnect

    public func disconnect(key: SessionKey) {
        if let vm = cache[key] {
            vm.disconnect()
        }
        cache.removeValue(forKey: key)
        activeSessions.removeAll { $0.key == key }
        liveActivity.sync(sessions: activeSessions)
    }

    public func disconnectAll() {
        for vm in cache.values { vm.disconnect() }
        cache.removeAll()
        activeSessions.removeAll()
        liveActivity.sync(sessions: activeSessions)
    }

    public func handleHostDeleted(_ host: Host) {
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

    public func handleScenePhaseChange(_ phase: ScenePhase) {
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
    public func sessionDidUpdate(hostID: UUID, workspaceName: String, awaitingPanes: Int, latestPrompt: String) {
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

#endif
