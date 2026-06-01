#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Opens native libghostty terminal windows backed by a local pty. This is the
/// macOS terminal — it uses the *same* `GhosttyTerminalSurface` and tmux/runtime
/// stack as iOS; only the transport differs (local pty here vs SSH on iOS).
@MainActor
public enum BentoTerminalWindow {
    private static var controllers: [GhosttyTerminalWindowController] = []

    /// Default session name used by the bare "New Terminal Window" entry.
    public nonisolated static let defaultSessionName = "bento-mac"

    /// Open a new terminal window attached to (or creating) the named tmux
    /// session over a local pty + `tmux -CC`.
    public static func newWindow(session: String = defaultSessionName) {
        open(choice: .createOrAttach(name: session), title: titleFor(session))
    }

    /// Open a new terminal window that spins up a detached tmux session matching
    /// `spec` (working dir, agent command, layout) and attaches in control mode.
    /// This is the path the menubar Agent wizard uses to launch into the native
    /// terminal instead of bouncing to a third-party app.
    public static func newWindow(agent spec: AgentSpec) {
        open(choice: .createAgent(spec: spec), title: titleFor(spec.sessionName))
    }

    private static func open(choice: TmuxStartChoice, title: String) {
        let controller = GhosttyTerminalWindowController(choice: choice, title: title)
        controllers.append(controller)
        controller.onClose = { [weak controller] in
            controllers.removeAll { $0 === controller }
        }
        controller.show()
    }

    private static func titleFor(_ session: String) -> String {
        session == defaultSessionName ? "Bento Terminal" : "Bento · \(session)"
    }
}

@MainActor
final class GhosttyTerminalWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel: TerminalViewModel
    private let paneHost: GhosttyTiledPaneHost
    private let choice: TmuxStartChoice
    private let windowTitle: String
    private let sessionKey: String
    var onClose: (() -> Void)?

    init(choice: TmuxStartChoice, title: String) {
        self.choice = choice
        self.windowTitle = title
        switch choice {
        case .createOrAttach(let name): self.sessionKey = name
        case .createAgent(let spec): self.sessionKey = spec.sessionName
        case .shareWithDesktop(let target): self.sessionKey = target
        case .noTmux: self.sessionKey = "local"
        }
        let theme = TerminalTheme(
            background: 0x0F1115,
            foreground: 0xE6E8EE,
            ansi: GhosttyTerminalWindowController.defaultAnsi,
            fontSize: 13
        )
        // Same shared TerminalViewModel as iOS, driving tmux -CC over a local
        // pty. The tiled pane host (AppKit) is the only platform-specific view.
        // Awaiting-input callbacks surface a macOS notification + Dock badge
        // (reusing the same StateDetectionService path iOS drives a Live
        // Activity from).
        let key = sessionKey
        let env = TerminalEnvironment(
            idealTerminalSize: { (120, 30) },
            onSessionUpdate: { _, session, awaiting, prompt in
                MacAwaitingNotifier.shared.update(
                    sessionKey: session.isEmpty ? key : session,
                    awaiting: awaiting, prompt: prompt)
            }
        )
        let vm = TerminalViewModel(
            host: Host(name: "Local"),
            transport: LocalPtyTransport(command: nil),
            environment: env
        )
        self.viewModel = vm
        self.paneHost = GhosttyTiledPaneHost(viewModel: vm, theme: theme)
        super.init()
    }

    func show() {
        // NOTE: we intentionally stay an .accessory (LSUIElement) app and do
        // NOT switch to .regular. Switching to .regular makes the app eligible
        // for the "terminate after last window closed" lifecycle (which SwiftUI
        // drives, bypassing the AppKit delegate), so closing the terminal would
        // kill the whole menubar app. Accessory apps don't auto-terminate on
        // last-window-close; activating + makeKey still gives full keyboard focus.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = windowTitle
        win.delegate = self
        // We hold the window in `window` and tear it down explicitly; let ARC
        // own its lifetime (avoids a release race during the close animation).
        win.isReleasedWhenClosed = false
        win.contentView = paneHost
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        // tmux -CC over the local pty → the shared VM produces PaneViewModels,
        // and GhosttyTiledPaneHost tiles them iTerm2-style.
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.connect()
            await self.viewModel.applyTmuxChoice(self.choice)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Stop rendering and free the ghostty surfaces BEFORE AppKit tears the
        // window down — otherwise the close animation commits a CoreAnimation
        // transaction against the half-freed Metal layer and crashes.
        paneHost.teardown()
        viewModel.disconnect()
        MacAwaitingNotifier.shared.clear(sessionKey: sessionKey)
        window?.delegate = nil
        window = nil
        onClose?()
    }

    /// Standard xterm 16-color palette (placeholder until ghostty palette
    /// configuration is wired in Phase 4).
    static let defaultAnsi: [UInt32] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]
}
#endif
