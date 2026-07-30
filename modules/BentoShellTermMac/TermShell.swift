#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoTermLink
import BentoTerminalPane
import BentoTmuxPane
import BentoUI
import BentoWorkbench
import Foundation
import SwiftTmux

/// Process-wide seams for the product-B (Bento Term) shell. One dedicated
/// workspace store (its own persist key, so the tmux tree never mixes with the
/// ACP app's), one TmuxPaneModule install, and the target the control client
/// speaks to.
///
/// **One target = one tmux session = one machine.** `target` is the machine
/// (`local`, or a host alias); the session it hosts is looked up here so a
/// pane's transport can find the live control client. Multi-host in one window
/// is deliberately not a thing — a window IS a session, and a session lives on
/// exactly one machine.
@MainActor
public enum TermShell {
    /// The product-B workspace store — dedicated key, ACP `launcher` left nil
    /// (a tmux pane establishes via `TmuxPaneRuntime.attach`, never the ACP
    /// ladder), so `spawn` just builds+attaches the runtime.
    public static let store = AgentWorkspaceStore(persistKey: "term_workspace_v1")

    /// The machine this shell speaks to. `local` is this Mac; anything else is
    /// an `~/.ssh/config` host alias, reached by spawning the system `ssh`.
    public static var target: String = "local"

    /// Session name used when nothing has been chosen yet.
    public static let defaultSessionName = "bento"

    /// target → tmux session name.
    public static var sessionNames: [String: String] = [:]

    private static var installed = false

    /// One-line app install: register the tmux pane module. Call from the app
    /// delegate at startup, then open a window.
    public static func install() {
        installTerminalAppearance()
        installPaneModule()
    }

    /// Point the renderer at the shared theme store (implementation and the
    /// frozen System-theme rule live in `TerminalAppearance`, which both tmux
    /// shells install).
    public static func installTerminalAppearance() {
        TerminalAppearance.install()
    }

    /// Register the tmux pane module on the term store exactly once. Every
    /// pane's transport rides the ONE control client `TermSessionHost` holds —
    /// where the daemon-era build opened a connection per pane, a control
    /// client already multiplexes every pane on the server, so there is
    /// nothing left to open.
    public static func installPaneModule() {
        guard !installed else { return }
        installed = true
        // Same one-time path, because this is the one that actually runs: the
        // app never calls `install()` — the first TerminalViewModel does this,
        // and it does so before any surface exists, which is the deadline for
        // the appearance (the runtime is a lazy singleton whose first surface
        // writes the color config).
        installTerminalAppearance()
        TmuxPaneModule.install(on: store) { instance in
            guard let link = TermSessionHost.shared.sessionLink else {
                return InMemoryTmuxTransport()   // no client yet; attach retries
            }
            return ControlModeTmuxTransport(pane: instance.pane, link: link)
        }
    }

    // MARK: - How the bytes get to tmux

    /// The pty command for a target: tmux itself for this Mac, `ssh <alias>`
    /// running tmux for anything else.
    ///
    /// macOS spawns the system `ssh` rather than speaking SSH in-process, and
    /// that is the whole remote story: `~/.ssh/config`, ProxyJump chains,
    /// agent keys, bastion rules and everything else the user's own setup
    /// already does, inherited for free and owned by nobody here. A host you
    /// can already `ssh` to is a host Bento Term can drive, with nothing
    /// installed on it.
    static func makeTransport(target: String, session: String) -> any TerminalTransport {
        let tmux = ["tmux", "-CC", "new-session", "-A", "-s", session]
        if target == "local" {
            return LocalPtyTransport(command: tmux)
        }
        // `-t`: tmux needs a tty on the far end, and ssh only allocates one
        // when asked for a command that is not a login shell.
        return LocalPtyTransport(command: ["ssh", "-t", target] + tmux)
    }

    /// macOS always owns the pty's argv, so tmux is the command — never a
    /// login shell we then type into. (iOS differs; see `TmuxSessionLink.Launch`.)
    static let launchStyle: TmuxSessionLink.Launch = .spawnedByTransport
}
#endif
