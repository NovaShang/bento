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
        ShellPaneRegistry.welcomeFlow = { addHost in AnyView(TermWelcomeView(addHost: addHost)) }
        seedHostFromEnvironment()
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

    /// Debug builds only: create a host from `BENTO_SEED_SSH_HOST`, formatted
    /// `user:password@hostname[:port]`.
    ///
    /// Exists because UI automation cannot type into a `SecureField` on iOS —
    /// the taps and the keystrokes both report success and the field stays
    /// empty — so without this the simulator loop cannot reach the one screen
    /// that matters, the live terminal. Same shape as the onboarding hooks
    /// (`BENTO_FORCE_FIRST_RUN`, `BENTO_HOME`): env-gated, DEBUG-only, and it
    /// goes through the ordinary `HostStore.add` so what gets tested is the
    /// real record, not a special one.
    static func seedHostFromEnvironment() {
        #if DEBUG
        let spec = ProcessInfo.processInfo.environment["BENTO_SEED_SSH_HOST"] ?? ""
        guard !spec.isEmpty,
              let at = spec.lastIndex(of: "@") else { return }
        let credentials = spec[spec.startIndex..<at].split(separator: ":", maxSplits: 1)
        guard credentials.count == 2 else { return }
        let endpoint = spec[spec.index(after: at)...].split(separator: ":", maxSplits: 1)
        let hostname = String(endpoint[0])
        let port = endpoint.count == 2 ? UInt16(endpoint[1]) ?? 22 : 22
        guard !HostStore.shared.hosts.contains(where: {
            $0.hostname == hostname && $0.username == String(credentials[0])
        }) else { return }

        let host = Host(hostname: hostname, port: port,
                        username: String(credentials[0]),
                        authMethod: .password, transport: .directTCP)
        try? KeychainService.shared.savePassword(String(credentials[1]),
                                                 for: host.id.uuidString)
        HostStore.shared.add(host)
        #endif
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
        // The Mac-login password lives in THIS device's keychain, so the link
        // cannot read it itself.
        link.loadKeychainPassword = { account in
            try? KeychainService.shared.loadPassword(for: account)
        }

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

    /// Every tmux session on the host, or why we could not find out.
    ///
    /// A one-shot `list-sessions` over its own SSH channel, which closes
    /// immediately. Deliberately NOT a control client: attaching one is how
    /// you JOIN a session, and merely browsing a host must never do that —
    /// an earlier version rode the default session and so resized whatever
    /// the user was really working in to this device's screen.
    ///
    /// Returns a reason rather than an empty list on failure. The two are not
    /// the same thing and the UI cannot tell them apart: a host that refused
    /// the password rendered exactly like a host with nothing running on it.
    enum SessionListing {
        case success([String])
        case failure(String)
    }

    static func listSessions(on host: Host) async -> SessionListing {
        guard case .directTCP = host.transport else {
            return .failure("\(host.displayName) is not reachable over SSH.")
        }
        let ssh = SSHService()
        await ssh.connect(host: host)
        switch ssh.state {
        case .connected: break
        case .failed(let message):
            return .failure("Couldn't connect to \(host.hostname): \(message)")
        case .connecting, .disconnected:
            return .failure("Couldn't connect to \(host.hostname).")
        }
        defer { ssh.disconnect() }

        // Through a LOGIN shell (`-l`), and that is load-bearing: an SSH exec
        // channel gets a minimal PATH — no `/opt/homebrew/bin` — so a bare
        // `tmux` is not found on the most common host there is, a Mac with
        // Homebrew, and the picker then says "No sessions yet" about a machine
        // with sessions running on it. (The launch path never hit this; it
        // types into a login shell, which is what this borrows.)
        //
        // A login shell also means the rc files run, and anything they PRINT —
        // MOTD, a banner, a stray echo in .zshrc — arrives on the same stdout.
        // Hence the markers and `parseTmuxLs`, restored from the pre-merge
        // product: the two marker halves are emitted contiguously by `printf`
        // but appear as separate shell tokens in any echo, so a `contains`
        // check cannot mismatch, and the parser additionally requires each
        // line's tail to look like `: N windows` so a banner line carrying a
        // colon cannot masquerade as a session. Plain `tmux ls` rather than
        // `-F '#{session_name}'` for exactly that reason — the stats tail IS
        // the evidence that a line is a session.
        let token = String(UUID().uuidString.prefix(8))
        let startA = "__BT_S_\(token)_", startB = "_GO__"
        let endA = "__BT_E_\(token)_", endB = "_DONE__"
        let script = "printf '\\n%s%s\\n' '\(startA)' '\(startB)';"
                   + " tmux ls 2>/dev/null;"
                   + " printf '%s%s\\n' '\(endA)' '\(endB)'"
        guard let out = await ssh.run("$SHELL -lc \(shellQuoted(script))") else {
            return .failure("Couldn't run tmux on \(host.hostname).")
        }
        // No server yet is the normal state of a machine you are about to open
        // your first session on — an empty list, not a failure. It is also
        // indistinguishable here from "tmux is not installed", and guessing
        // wrong in the loud direction would put a false error in front of
        // every first-time user.
        return .success(TmuxParsers.parseTmuxLs(
            out, startMarker: startA + startB, endMarker: endA + endB))
    }

    /// Single-quote for a POSIX shell, closing and reopening around any quote.
    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private var stores: [String: AgentWorkspaceStore] = [:]
    private var links: [String: TmuxSessionLink] = [:]
    private var authorities: [String: TmuxAuthority] = [:]
}
