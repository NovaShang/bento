import Foundation
import BentoFoundation
import BentoLink
import BentoWorkbench
import BentoTmuxPane
import BentoShelliOS

// Product B's composition-root glue, the tmux twin of product A's `AcpStore`
// (docs/term-ios-port.md §3): how a paired host resolves to a tmux-backed
// workspace store, and how the generic shell builds a tmux pane VC. The generic
// `SessionManager` / `ShellPaneRegistry` in BentoShelliOS carry the seams; this
// installs the tmux side of each. No BentoAgentPane, no unix socket — on iOS the
// only reach is the BentoLink sealed relay.
@MainActor
enum TmuxShell {
    /// Register the tmux pane VC factory + preview-context seam. Called once
    /// from `BentoApp.init`.
    static func install() {
        ShellPaneRegistry.paneControllerFactory = { TermPaneVC(store: $0) }
        // Preview-context for the Files tree root is a tmux-pane cwd read — a
        // daemon-side capability not yet wired on this path (flagged, §2.5-adjacent).
        ShellPaneRegistry.previewContextProvider = { _, _ in nil }
    }

    /// One tmux workspace store per paired daemon, relay-backed. The store's ACP
    /// launcher is left nil (a tmux pane establishes via `TmuxPaneRuntime.attach`,
    /// never the ACP ladder); `TmuxPaneModule.install` wires the runtime factory
    /// whose transport is one `LinkTmuxTransport` per pane over a fresh sealed
    /// relay stream. nil when the host isn't a paired relay daemon.
    static func store(for host: Host) -> AgentWorkspaceStore? {
        guard case .relay(let daemonID, let fingerprint, let deviceID) = host.transport,
              case .privateKey(let keyLabel) = host.authMethod,
              let key = try? KeychainService.shared.loadPrivateKey(label: keyLabel)
        else { return nil }

        if let existing = stores[daemonID] { return existing }

        let config = AcpRelayConfig(
            relayBaseURL: RelayPairingService.relayBaseURLString,
            daemonID: daemonID,
            deviceID: deviceID,
            devicePrivateKey: key,
            hostKeyFingerprint: fingerprint)
        let store = AgentWorkspaceStore(persistKey: "term_workspace_\(daemonID)")
        TmuxPaneModule.install(on: store) { instance in
            LinkTmuxTransport(instanceID: instance, sessionName: "") {
                AcpHostTransportFactory.relay(config: config)
            }
        }
        // Structure is fed by DaemonAuthority over statechanged (the Mac term
        // shell's TerminalViewModel pattern); the iOS structure-feed model is a
        // flagged follow-up — the store + transport wiring below is what builds.
        stores[daemonID] = store
        return store
    }

    private static var stores: [String: AgentWorkspaceStore] = [:]
}
