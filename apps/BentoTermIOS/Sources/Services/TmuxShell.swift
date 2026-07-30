import BentoFoundation
import BentoShelliOS
import BentoTermLink
import BentoTmuxPane
import BentoWorkbench
import Foundation
import SwiftTmux

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
    }

    /// One tmux workspace store per host, each with its own control client.
    ///
    /// The store's ACP launcher is left nil (a tmux pane establishes via
    /// `TmuxPaneRuntime.attach`, never the ACP ladder). Every pane's transport
    /// rides the ONE control client this host's link holds — a control client
    /// already multiplexes every pane on the server, so there is nothing
    /// per-pane left to open.
    static func store(for host: Host) -> AgentWorkspaceStore? {
        guard case .directTCP = host.transport else { return nil }
        let key = host.id.uuidString
        if let existing = stores[key] { return existing }

        let link = TmuxSessionLink(
            transport: SSHService(), target: host.hostname, sessionName: sessionName)
        let store = AgentWorkspaceStore(persistKey: "term_workspace_\(key)")
        let authority = TmuxAuthority(link: link)

        TmuxPaneModule.install(on: store) { instance in
            ControlModeTmuxTransport(pane: instance.pane, link: link)
        }

        Task {
            // 80×24 is only the pre-layout seed tmux needs to attach at all;
            // `refresh-client` corrects it the moment a surface has a real grid.
            await link.connect(host: host, cols: 80, rows: 24, launch: .typedIntoShell())
        }

        links[key] = link
        authorities[key] = authority
        stores[key] = store
        return store
    }

    /// One window = one session = one machine, so the name only has to be
    /// stable per host.
    private static let sessionName = "bento"

    static func link(for host: Host) -> TmuxSessionLink? { links[host.id.uuidString] }
    static func authority(for host: Host) -> TmuxAuthority? { authorities[host.id.uuidString] }

    private static var stores: [String: AgentWorkspaceStore] = [:]
    private static var links: [String: TmuxSessionLink] = [:]
    private static var authorities: [String: TmuxAuthority] = [:]
}
