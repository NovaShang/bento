import BentoShellTermMac
import SwiftUI

@main
struct BentoMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: appDelegate)
                .environmentObject(appDelegate.bento)
        } label: {
            // A small wrapper so the always-present menu-bar label can bridge an
            // AppKit request (the term toolbar's ⚙) to SwiftUI's reliable
            // `openSettings` action — `showSettingsWindow:` doesn't fire in a
            // MenuBarExtra app.
            MenubarLabel()
        }
        .menuBarExtraStyle(.menu)
        // The "Shell" menu drives the tmux-backed tiled terminal. Items dispatch
        // through the responder chain (BentoTermPaneAction) to the focused
        // TermTiledPaneHost. SwiftUI owns the main menu in a MenuBarExtra app,
        // so the menu must be declared here rather than via NSApp.mainMenu.
        .commands { TerminalCommands() }

        Settings {
            SettingsView().environmentObject(appDelegate.bento)
        }
    }
}

extension Notification.Name {
    /// Posted by the term toolbar's ⚙ to open the SwiftUI Settings scene.
    static let bentoOpenSettings = Notification.Name("bentoOpenSettings")
}

/// The always-present menu-bar label. It holds SwiftUI's `openSettings` action
/// and triggers it when the AppKit toolbar posts `.bentoOpenSettings`.
struct MenubarLabel: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Template image — macOS tints to match the dark/light menu bar.
        Image("MenubarIcon")
            .onReceive(NotificationCenter.default.publisher(for: .bentoOpenSettings)) { _ in
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// The Shell menu for Bento Term windows — tmux semantics kept faithful to the
/// frozen product (docs/term-shell-port.md #4): ⌘T = new tmux window,
/// ⇧⌘T = new session, Split -h/-v, ⌘0-9 = select window by tmux index,
/// ⇧⌘R = track session size, the ⌘F/⌘G/⇧⌘G/⌘E find family (scrollback-scoped).
struct TerminalCommands: Commands {
    var body: some Commands {
        CommandMenu("Shell") {
            Button("Command Palette…") { BentoTermWindow.presentCommandPalette() }
                .keyboardShortcut("p", modifiers: .command)
            Divider()
            // Scoped to the ACTIVE PANE's scrollback. Standard macOS find keys.
            Button("Find…") { BentoTermPaneAction.dispatch(BentoTermPaneAction.findInPane) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { BentoTermPaneAction.dispatch(BentoTermPaneAction.findNext) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { BentoTermPaneAction.dispatch(BentoTermPaneAction.findPrevious) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") {
                BentoTermPaneAction.dispatch(BentoTermPaneAction.useSelectionForFind)
            }
            .keyboardShortcut("e", modifiers: .command)
            Divider()
            // ⌘T = new WINDOW in the session you're in (tmux's reflex `prefix-c`);
            // ⇧⌘T = a whole new session.
            Button("New tmux Window") { BentoTermPaneAction.dispatch(BentoTermPaneAction.newTmuxWindow) }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Session") { BentoTermWindow.newSessionTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Split Right (-h)") { BentoTermPaneAction.dispatch(BentoTermPaneAction.splitVertically) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down (-v)") { BentoTermPaneAction.dispatch(BentoTermPaneAction.splitHorizontally) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Select Next Pane") { BentoTermPaneAction.dispatch(BentoTermPaneAction.nextPane) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Select Previous Pane") { BentoTermPaneAction.dispatch(BentoTermPaneAction.previousPane) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Swap Pane Up") { BentoTermPaneAction.dispatch(BentoTermPaneAction.swapPaneUp) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Swap Pane Down") { BentoTermPaneAction.dispatch(BentoTermPaneAction.swapPaneDown) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Toggle Zoom") { BentoTermPaneAction.dispatch(BentoTermPaneAction.toggleZoom) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            // ⌘0..⌘9 → the window whose tmux INDEX is that digit.
            Menu("Select Window") {
                ForEach(0...9, id: \.self) { n in
                    Button("Window \(n)") {
                        BentoTermPaneAction.dispatch(BentoTermPaneAction.selectWindow[n])
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
            Divider()
            Button("Track Session Size to This Window") { BentoTermWindow.trackActiveSessionSize() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Close Pane") { BentoTermPaneAction.dispatch(BentoTermPaneAction.closePane) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { BentoTermWindow.closeMainWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}

/// Windows manages the small set of secondary windows the menubar can spawn
/// for Pair / Wizard / Devices / FirstRun. We open them via AppKit so we don't
/// fight SwiftUI Scene plumbing for menubar apps.
enum Windows {
    enum Kind { case pair, wizard, devices, firstRun }

    @MainActor
    static func show(_ kind: Kind, env: BentoCLI) {
        let title: String
        let content: AnyView
        switch kind {
        case .pair:
            title = "Pair iPhone"
            content = AnyView(PairingWindow().environmentObject(env))
        case .wizard:
            title = "New session"
            content = AnyView(AgentWizardWindow().environmentObject(env))
        case .devices:
            title = "Paired devices"
            content = AnyView(DevicesWindow().environmentObject(env))
        case .firstRun:
            title = "Welcome to Bento"
            content = AnyView(FirstRunWindow().environmentObject(env))
        }
        let host = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
