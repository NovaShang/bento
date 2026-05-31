#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Opens native libghostty terminal windows backed by a local pty. This is the
/// macOS terminal — it uses the *same* `GhosttyTerminalSurface` and tmux/runtime
/// stack as iOS; only the transport differs (local pty here vs SSH on iOS).
@MainActor
public enum BentoTerminalWindow {
    private static var controllers: [GhosttyTerminalWindowController] = []

    /// Open a new terminal window. `command` overrides the login shell, e.g.
    /// pass a `tmux -CC` invocation to drive control-mode panes.
    public static func newWindow(command: [String]? = nil) {
        let controller = GhosttyTerminalWindowController(command: command)
        controllers.append(controller)
        controller.onClose = { [weak controller] in
            controllers.removeAll { $0 === controller }
        }
        controller.show()
    }
}

@MainActor
final class GhosttyTerminalWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel: TerminalViewModel
    private let paneHost: GhosttyTiledPaneHost
    private let sessionName = "bento-mac"
    var onClose: (() -> Void)?

    init(command: [String]?) {
        let theme = TerminalTheme(
            background: 0x0F1115,
            foreground: 0xE6E8EE,
            ansi: GhosttyTerminalWindowController.defaultAnsi,
            fontSize: 13
        )
        // Same shared TerminalViewModel as iOS, driving tmux -CC over a local
        // pty. The tiled pane host (AppKit) is the only platform-specific view.
        let env = TerminalEnvironment(idealTerminalSize: { (120, 30) })
        let vm = TerminalViewModel(
            host: Host(name: "Local"),
            transport: LocalPtyTransport(command: command),
            environment: env
        )
        self.viewModel = vm
        self.paneHost = GhosttyTiledPaneHost(viewModel: vm, theme: theme)
        super.init()
    }

    func show() {
        // A menubar (accessory) app must become a regular app to show and focus
        // a real window with keyboard input.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Bento Terminal"
        win.delegate = self
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
            await self.viewModel.applyTmuxChoice(.createOrAttach(name: self.sessionName))
        }
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.disconnect()
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
