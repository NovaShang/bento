import BentoFoundation
import BentoShelliOS
import BentoTermLink
import BentoTmuxPane
import BentoWorkbench
import Foundation
import SwiftTmux
import SwiftUI
import UIKit

// Product B's composition-root glue, the tmux twin of product A's `AcpStore`
// (docs/term-ios-port.md §3): how a host resolves to a tmux-backed workspace
// store, and how the generic shell builds a tmux pane VC. The generic
// `SessionManager` / `ShellPaneRegistry` in BentoShelliOS carry the seams; this
// installs the tmux side of each.
//
// The reach is SSH — the same reach the Mac has, to the same kind of machine,
// with nothing installed on it. A phone has no `ssh` binary and cannot fork, so
// it speaks the protocol in-process (Citadel) instead of spawning one; and
// because an SSH channel hands back a login SHELL rather than an argv, the tmux
// launch line has to be typed into it. That is the entire iOS/macOS
// difference, and it is named in `TmuxSessionLink.Launch`.
@MainActor
enum TmuxShell {
    /// Register the tmux pane VC factory + preview-context seam. Called once
    /// from `BentoApp.init`.
    static func install() {
        // Same seam the Mac shell installs: without it every surface renders on
        // the provider's built-in default instead of the user's theme / the OS
        // appearance. Runs here because BentoApp.init is before any surface.
        TerminalAppearance.install()
        ShellPaneRegistry.paneControllerFactory = { TermPaneVC(store: $0) }
        ShellPaneRegistry.previewContextProvider = { _, _ in nil }
        // Bento Term reaches a machine by opening an SSH connection to it, so
        // the `+` button asks for a hostname — not a pairing code from a daemon
        // this product no longer has.
        ShellPaneRegistry.hostAddOptions = [
            HostAddOption(id: "ssh", title: "Add SSH Host…", systemImage: "terminal") { dismiss in
                AnyView(
                    NavigationStack {
                        HostEditView(mode: .add) { host in
                            HostStore.shared.add(host)
                            dismiss()
                        }
                    }
                )
            },
        ]
    }

    /// One tmux workspace store per host, each with its own control client.
    ///
    /// The store's ACP launcher is left nil (a tmux pane establishes via
    /// `TmuxPaneRuntime.attach`, never the ACP ladder). Every pane's transport
    /// rides the ONE control client this host's link holds — a control client
    /// already multiplexes every pane on the server, so there is nothing
    /// per-pane left to open.
    static func store(for host: Host, session: String) -> AgentWorkspaceStore? {
        guard case .directTCP = host.transport else { return nil }
        let session = session.isEmpty ? defaultSessionName : session
        let key = "\(host.id.uuidString)/\(session)"
        if let existing = stores[key] { return existing }

        // Joining work that is already on a screen somewhere means a GROUPED
        // session: tmux gives this device its own session sharing the target's
        // windows, so both see the same panes and each carries its own size.
        // Attaching directly instead would make whichever client arrived last
        // impose its geometry on the other — a phone crushing a Mac's panes to
        // phone dimensions, which is what happened before this existed.
        let joining = existingSessions.contains(session)
        let ownSession = joining ? "\(session)-\(deviceSuffix)" : session
        let link = TmuxSessionLink(
            transport: SSHService(), target: host.hostname, sessionName: ownSession)
        let store = AgentWorkspaceStore(persistKey: "term_workspace_\(key)")
        let authority = TmuxAuthority(link: link)

        TmuxPaneModule.install(on: store) { instance in
            ControlModeTmuxTransport(pane: instance.pane, link: link)
        }

        Task {
            // 80×24 is only the pre-layout seed tmux needs to attach at all;
            // `refresh-client` corrects it the moment a surface has a real grid.
            // Our own session either way — grouped or freshly created — so
            // declaring a size affects nobody else.
            await link.connect(
                host: host, cols: 80, rows: 24,
                launch: .typedIntoShell(groupWith: joining ? session : nil),
                size: .declareOurs)
        }

        links[key] = link
        authorities[key] = authority
        stores[key] = store
        return store
    }

    /// Used when the picker hands over an empty name.
    private static let defaultSessionName = "bento"

    /// Suffix for this device's grouped session. Stable per device so
    /// reconnecting rejoins the same one instead of littering the server.
    private static let deviceSuffix: String = {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }()

    /// Sessions seen on the host at the time `store(for:session:)` was called.
    /// Populated by the picker's own listing, which already ran.
    static var existingSessions: Set<String> = []

    static func link(for host: Host, session: String) -> TmuxSessionLink? {
        links["\(host.id.uuidString)/\(session.isEmpty ? defaultSessionName : session)"]
    }

    /// Every tmux session on the host, for the picker.
    ///
    /// A one-shot `list-sessions` over its own SSH channel, which closes
    /// immediately. Deliberately NOT a control client: attaching one is how
    /// you JOIN a session, and merely browsing a host must never do that —
    /// the earlier version rode the default session and so resized whatever
    /// the user was really working in to this device's screen.
    static func sessionNames(on host: Host) async -> [String] {
        guard case .directTCP = host.transport else { return [] }
        let ssh = SSHService()
        await ssh.connect(host: host)
        guard case .connected = ssh.state else { return [] }
        defer { ssh.disconnect() }
        guard let out = await ssh.run("tmux list-sessions -F '#{session_name}'") else { return [] }
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static var stores: [String: AgentWorkspaceStore] = [:]
    private static var links: [String: TmuxSessionLink] = [:]
    private static var authorities: [String: TmuxAuthority] = [:]
}
