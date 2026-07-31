import Foundation
import BentoCore
import BentoShelliOS

// Product A's composition-root glue, carved out of the generic shell
// (docs/term-ios-port.md §1b): how a paired host resolves to an ACP workspace
// store, and the ACP session picker's discovery lister. The generic
// `SessionManager` in BentoShelliOS keeps only the injectable
// `WorkspaceConnectionSource` seam; this is what `BentoApp` installs into it.
// Product B installs the tmux twin instead.

/// Product A's side of the connection seam.
///
/// Only `store(for:workspace:)` does anything here, and that is the honest
/// answer rather than an omission: an ACP workspace's connection is the paired
/// daemon's relay channel, and the daemon — not this app — decides when it
/// lives and dies. Leaving a session on the phone must NOT stop the agents,
/// which is the opposite of product B, where the control client is ours and
/// leaving it attached silently reshapes somebody else's panes.
@MainActor
final class AcpConnections: WorkspaceConnectionSource {
    static let shared = AcpConnections()

    func store(for host: Host, workspace: String) -> AgentWorkspaceStore? {
        SessionManager.acpStore(for: host)
    }

    func release(host: Host, workspace: String) {}
    func suspend() {}
    func resume() async {}
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
        let store = AgentWorkspaceStore.relayStore(
            daemonID: daemonID,
            deviceID: deviceID,
            hostKeyFingerprint: fingerprint,
            devicePrivateKey: deviceKey,
            relayBaseURL: RelayPairingService.relayBaseURLString)
        // Same store may come back memoized — install is idempotent.
        AcpPaneModule.install(on: store)
        return store
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
