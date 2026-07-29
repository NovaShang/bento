#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoLink
import BentoTmuxPane
import BentoWorkbench
import Foundation

/// Process-wide seams for the product-B (Bento Term) shell. One dedicated
/// workspace store (its own persist key, so the tmux tree never mixes with the
/// ACP app's), one TmuxPaneModule install, and the daemon socket + per-target
/// session-name table the pane-transport factory reads.
///
/// v1 boundary (docs/tmux-host-design.md §"v1 拒绝的 verb"): **one target = one
/// tmux session**. `target` is the machine (`local`); the session it hosts is
/// looked up here so a pane's `LinkTmuxTransport` can ensure the right session
/// name. Multi-session-per-machine is a daemon multi-target extension — flagged
/// in the port notes, not faked here.
@MainActor
public enum TermShell {
    /// The product-B workspace store — dedicated key, ACP `launcher` left nil
    /// (a tmux pane establishes via `TmuxPaneRuntime.attach`, never the ACP
    /// ladder), so `spawn` just builds+attaches the runtime.
    public static let store = AgentWorkspaceStore(persistKey: "term_workspace_v1")

    /// target → tmux session name, populated by each `TermWorkspaceModel` before
    /// its panes attach so the shared transport factory can ensure the session.
    public static var sessionNames: [String: String] = [:]

    /// The local daemon's unix socket (resolved the way DaemonAgentLauncher
    /// resolves it — $BENTO_HOME else ~/.bento-acp).
    public static var socketPath: String = DaemonAgentLauncher().socketPath

    private static var installed = false

    /// One-line app install: register the tmux pane module and adopt the daemon
    /// socket. Call from the app delegate at startup, then open a window.
    public static func install(socketPath: String? = nil) {
        if let socketPath { self.socketPath = socketPath }
        installPaneModule()
    }

    /// Register the tmux pane module on the term store exactly once. The
    /// transport factory builds one `LinkTmuxTransport` per pane instance, over
    /// the local daemon socket, ensuring the target's session by name.
    public static func installPaneModule() {
        guard !installed else { return }
        installed = true
        TmuxPaneModule.install(on: store) { instance in
            LinkTmuxTransport(
                instanceID: instance,
                sessionName: sessionNames[instance.target] ?? "",
                socketPath: socketPath)
        }
    }
}
#endif
