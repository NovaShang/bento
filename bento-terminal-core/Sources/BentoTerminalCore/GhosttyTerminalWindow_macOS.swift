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
    private let pty = LocalPty()
    private let command: [String]?
    private var ptyStarted = false
    var onClose: (() -> Void)?

    init(command: [String]?) {
        self.command = command
        let theme = TerminalTheme(
            background: 0x0F1115,
            foreground: 0xE6E8EE,
            ansi: GhosttyTerminalWindowController.defaultAnsi,
            fontSize: 13
        )
        self.surface = GhosttyTerminalSurface(theme: theme)
        super.init()
    }

    func show() {
        // A menubar (accessory) app must become a regular app to show and focus
        // a real window with keyboard input.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        // Wire surface <-> pty BEFORE adding the surface to the window. Adding
        // it as contentView triggers surface creation and the first size report
        // synchronously; if onSizeChanged isn't set yet, currentSize gets
        // latched and the dedup guard would suppress every later report, so the
        // pty would never start.
        surface.onInput = { [weak self] data in self?.pty.write(data) }
        pty.onData = { [weak self] data in self?.surface.feed(data) }
        pty.onExit = { [weak self] in self?.window?.close() }

        // Start the pty once the surface reports its authoritative grid, so the
        // shell's initial size matches what's rendered. Subsequent reports
        // resize the pty.
        surface.onSizeChanged = { [weak self] size in
            guard let self else { return }
            self.startOrResizePty(cols: size.columns, rows: size.rows)
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

        // If the surface already reported a size during contentView assignment,
        // start the pty now (the callback above won't fire again for that size).
        if let size = surface.currentSize {
            startOrResizePty(cols: size.columns, rows: size.rows)
        }
    }

    private func startOrResizePty(cols: Int, rows: Int) {
        if ptyStarted {
            pty.resize(cols: cols, rows: rows)
        } else {
            ptyStarted = true
            pty.start(cols: cols, rows: rows, command: command)
        }
    }

    func windowWillClose(_ notification: Notification) {
        pty.stop()
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
