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
    private let surface: GhosttyTerminalSurface
    private let viewModel: TerminalViewModel
    var onClose: (() -> Void)?

    init(command: [String]?) {
        let theme = TerminalTheme(
            background: 0x0F1115,
            foreground: 0xE6E8EE,
            ansi: GhosttyTerminalWindowController.defaultAnsi,
            fontSize: 13
        )
        let surface = GhosttyTerminalSurface(theme: theme)
        self.surface = surface
        // The macOS terminal runs the *same* shared TerminalViewModel as iOS;
        // only the transport differs — a local pty here vs SSH on iOS. The PTY's
        // initial size comes from the surface's authoritative grid once laid out.
        let env = TerminalEnvironment(idealTerminalSize: { [weak surface] in
            if let s = surface?.currentSize { return (s.columns, s.rows) }
            return (80, 24)
        })
        self.viewModel = TerminalViewModel(
            host: Host(name: "Local"),
            transport: LocalPtyTransport(command: command),
            environment: env
        )
        super.init()
    }

    func show() {
        // A menubar (accessory) app must become a regular app to show and focus
        // a real window with keyboard input.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        // Bind the surface to the shared VM (single-pane / non-tmux local shell).
        surface.onInput = { [weak self] data in self?.viewModel.sendData(data) }
        // onRawDataReceived is a @Sendable callback (may fire off-main); hop to
        // the main actor before touching the surface (same pattern as iOS).
        viewModel.onRawDataReceived = { [weak self] data in
            DispatchQueue.main.async { self?.surface.feed(data) }
        }
        surface.onSizeChanged = { [weak self] size in
            self?.viewModel.resizeTerminal(cols: size.columns, rows: size.rows)
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Bento Terminal"
        win.delegate = self
        win.contentView = surface
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(surface)
        window = win

        // Drive the shared session lifecycle: connect (local pty) → plain shell.
        // tmux multi-pane on macOS would use a tmux -CC choice + a pane-hosting
        // view (future work).
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.connect()
            await self.viewModel.applyTmuxChoice(.noTmux)
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
