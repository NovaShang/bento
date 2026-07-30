#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoLink
import BentoTerminalPane
import BentoTmuxPane
import BentoUI
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

    /// The one tmux server target v1 speaks to (the local daemon's real
    /// default-socket server).
    public static var target: String = "local"

    /// target → tmux session name, populated by each ensure before panes
    /// attach so the shared transport factory can ensure the session.
    public static var sessionNames: [String: String] = [:]

    /// The local daemon's unix socket (resolved the way DaemonAgentLauncher
    /// resolves it — $BENTO_HOME else ~/.bento-acp).
    public static var socketPath: String = DaemonAgentLauncher().socketPath

    private static var installed = false

    /// One-line app install: register the tmux pane module and adopt the daemon
    /// socket. Call from the app delegate at startup, then open a window.
    public static func install(socketPath: String? = nil) {
        if let socketPath { self.socketPath = socketPath }
        installTerminalAppearance()
        installPaneModule()
    }

    /// Feed the rendering base the theme facts it used to read for itself.
    ///
    /// The frozen runtime called `ThemeStore.shared` directly; extracting
    /// BentoTerminalPane replaced that with an injected provider so the
    /// renderer depends on no theme store — but nothing was ever injected, so
    /// every surface ran on the provider's built-in default and stopped
    /// following both the Mac's light/dark and the user's theme choice.
    ///
    /// Frozen semantics preserved exactly: the system-adaptive "System" theme
    /// writes NO palette (ghostty's own look follows the OS appearance — that
    /// is what makes the terminal track the Mac), every other theme — including
    /// "System (Light)" — writes its explicit colors. `isDark` still rides
    /// along so programs inside the terminal get the right color-scheme report.
    /// `AppDelegate` posts `.terminalThemeChanged` on appearance flips, which
    /// re-invokes this provider and recolors open surfaces live.
    public static func installTerminalAppearance() {
        GhosttyRuntime.appearanceProvider = {
            let store = ThemeStore.shared
            return appearance(from: store.current,
                              fontFamily: store.ghosttyFontFamily,
                              fontSize: store.fontSize)
        }
    }

    /// The theme → renderer mapping, pure so tests can pin the System rule.
    nonisolated static func appearance(from theme: TerminalColorTheme,
                                       fontFamily: String?,
                                       fontSize: Double) -> GhosttyRuntimeAppearance
    {
        let palette: GhosttyRuntimeAppearance.Palette? =
            theme.id == TerminalColorTheme.systemID
            ? nil
            : .init(background: theme.bg, foreground: theme.fg,
                    cursor: theme.cursor, ansi: theme.ansi)
        return GhosttyRuntimeAppearance(palette: palette,
                                        fontFamily: fontFamily,
                                        fontSize: fontSize,
                                        isDark: theme.isDark)
    }

    /// Register the tmux pane module on the term store exactly once. The
    /// transport factory builds one `LinkTmuxTransport` per pane instance, over
    /// the local daemon socket, ensuring the target's session by name.
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
            LinkTmuxTransport(
                instanceID: instance,
                sessionName: sessionNames[instance.target] ?? "",
                socketPath: socketPath)
        }
    }
}
#endif
