import BentoFoundation
import BentoShelliOS
import BentoTermLink
import BentoTmuxPane
import BentoUI
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
final class TmuxShell: ObservableObject, WorkspaceConnectionSource {
    static let shared = TmuxShell()

    /// Register the tmux pane VC factory + preview-context seam. Called once
    /// from `BentoApp.init`.
    static func install() {
        // Same seam the Mac shell installs: without it every surface renders on
        // the provider's built-in default instead of the user's theme / the OS
        // appearance. Runs here because BentoApp.init is before any surface.
        TerminalAppearance.install()
        ShellPaneRegistry.paneControllerFactory = { TermPaneVC(store: $0) }
        ShellPaneRegistry.previewContextProvider = { _, _ in nil }
        // This object IS the shell's connection source: it answers where a
        // workspace comes from AND what happens to the control client when the
        // user leaves, backgrounds, or comes back. Those used to be separate
        // questions with only the first one answered.
        SessionManager.shared.connections = shared
        ShellPaneRegistry.connectionBanner = { host, session in
            AnyView(TmuxConnectionBanner(host: host, session: session))
        }
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
    func store(for host: Host, workspace: String) -> AgentWorkspaceStore? {
        guard case .directTCP = host.transport else { return nil }
        let session = workspace.isEmpty ? Self.defaultSessionName : workspace
        let key = Self.key(host: host, session: session)
        if let existing = stores[key] { return existing }

        // Joining work that is already on a screen somewhere means a GROUPED
        // session: tmux gives this device its own session sharing the target's
        // windows, so both see the same panes and each carries its own size.
        // Attaching directly instead would make whichever client arrived last
        // impose its geometry on the other — a phone crushing a Mac's panes to
        // phone dimensions, which is what happened before this existed.
        let joining = Self.existingSessions.contains(session)
        let ownSession = joining ? "\(session)-\(Self.deviceSuffix)" : session
        let link = TmuxSessionLink(
            transport: SSHService(), target: host.hostname, sessionName: ownSession)
        let store = AgentWorkspaceStore(persistKey: "term_workspace_\(key)")
        let authority = TmuxAuthority(link: link)

        let module = TmuxPaneModule.install(on: store) { instance in
            ControlModeTmuxTransport(pane: instance.pane, link: link)
        }
        module.isLocalLink = false

        link.onPhaseChanged = { [weak self] phase in self?.phases[key] = phase }

        Task {
            // The device's REAL grid, not 80×24. tmux resolves a session's size
            // from what its clients declare, so a client that declares a
            // placeholder gets a session shaped like the placeholder — and this
            // one is `.declareOurs`, meaning the size it names is the size the
            // session takes. Our own session either way (grouped when we are
            // joining work already on another screen), so naming it honestly
            // affects nobody else.
            let grid = Self.idealTerminalGrid()
            await link.connect(
                host: host, cols: grid.cols, rows: grid.rows,
                launch: .typedIntoShell(groupWith: joining ? session : nil),
                size: .declareOurs)
        }

        links[key] = link
        authorities[key] = authority
        stores[key] = store
        return store
    }

    /// The user left this workspace (or it was evicted). Tear the control
    /// client down.
    ///
    /// Without this the link lived forever: the phone stayed attached to the
    /// tmux server, kept its seat in the `window-size` election, and went on
    /// shaping the panes of whichever device was still really in use. "I closed
    /// it" has to mean the far end agrees.
    func release(host: Host, workspace: String) {
        let session = workspace.isEmpty ? Self.defaultSessionName : workspace
        let key = Self.key(host: host, session: session)
        links[key]?.disconnect()
        links[key] = nil
        authorities[key] = nil
        stores[key] = nil
        phases[key] = nil
    }

    func suspend() {
        for link in links.values { link.suspendForBackground() }
    }

    func resume() async {
        for link in links.values { await link.resumeFromBackground() }
    }

    /// Phase per live link, for the workspace screen's banner.
    @Published private(set) var phases: [String: TmuxSessionLink.Phase] = [:]

    func phase(for host: Host, session: String) -> TmuxSessionLink.Phase? {
        phases[Self.key(host: host, session: session.isEmpty ? Self.defaultSessionName : session)]
    }

    func retry(host: Host, session: String) {
        links[Self.key(host: host, session: session.isEmpty ? Self.defaultSessionName : session)]?
            .retry()
    }

    /// This device's terminal grid, in cells.
    ///
    /// Measured from the real screen and the real terminal font rather than
    /// assumed: `refresh-client -C` is the only thing that tells tmux how big
    /// this client is, and a session sized from a guess wraps every line in
    /// every pane wrongly until something happens to resize it. The 110pt
    /// deduction is the chrome above and below a pane (title bar + keyboard
    /// accessory); the floors keep a rotation mid-layout from declaring a
    /// degenerate grid.
    static func idealTerminalGrid() -> (cols: Int, rows: Int) {
        let screen = UIScreen.main.bounds
        let size = ThemeStore.shared.fontSize
        let family = ThemeStore.shared.ghosttyFontFamily
        let font = family.flatMap { UIFont(name: $0, size: size) }
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let cell = NSString(string: "M").size(withAttributes: [.font: font])
        guard cell.width > 0, cell.height > 0 else { return (80, 24) }
        let availableHeight = screen.height - 110
        return (max(Int(screen.width / cell.width), 40),
                max(Int(availableHeight / cell.height), 20))
    }

    /// Re-declare every live client's viewport — on rotation, on a font change.
    /// tmux only learns a client's size when the client says so.
    func redeclareViewports() {
        let grid = Self.idealTerminalGrid()
        for link in links.values { link.declareViewport(cols: grid.cols, rows: grid.rows) }
    }

    private static func key(host: Host, session: String) -> String {
        "\(host.id.uuidString)/\(session)"
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

    func link(for host: Host, session: String) -> TmuxSessionLink? {
        links[Self.key(host: host, session: session.isEmpty ? Self.defaultSessionName : session)]
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

    private var stores: [String: AgentWorkspaceStore] = [:]
    private var links: [String: TmuxSessionLink] = [:]
    private var authorities: [String: TmuxAuthority] = [:]
}
