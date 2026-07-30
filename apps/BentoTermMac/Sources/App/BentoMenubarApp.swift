import BentoShellTermMac
import BentoFoundation
import BentoMenuKit
import BentoTerminalPane
import BentoUI
import SwiftUI

/// Bento Term is a normal Mac app: a Dock icon, windows, and ⌘Q meaning ⌘Q.
///
/// It used to be a menu-bar resident, because it owned a daemon that outlived
/// its windows and something had to represent it. It doesn't own one any more —
/// the thing that has to survive a closed window is the tmux server, and that
/// is the user's, not ours, and it survives on its own as it always has.
/// So there is nothing left to sit in the menu bar and nothing left running
/// after you quit.
@main
struct BentoTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Terminal windows are opened from AppKit (BentoTerminalWindow), so the
        // only SwiftUI scene is Settings — which is also where the main menu is
        // declared from.
        Settings {
            SettingsView().environmentObject(appDelegate.bento)
        }
        .commands { TerminalCommands() }
    }
}

extension Notification.Name {
    /// Posted by the terminal toolbar's ⚙ to open the SwiftUI Settings scene.
    static let bentoOpenSettings = Notification.Name("bentoOpenSettings")
}

/// The Shell menu for Bento terminal windows (split / zoom / navigate / close).
struct TerminalCommands: Commands {
    var body: some Commands {
        CommandMenu("Shell") {
            Button("Command Palette…") { BentoTerminalWindow.presentCommandPalette() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Toggle Preview Panel") { BentoTerminalWindow.togglePreviewDock() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            // Scoped to the ACTIVE PANE's scrollback — the omnibox above is the
            // app-wide one. Standard macOS find keys so nobody has to learn them.
            Button("Find…") { BentoPaneAction.dispatch(BentoPaneAction.findInPane) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { BentoPaneAction.dispatch(BentoPaneAction.findNext) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { BentoPaneAction.dispatch(BentoPaneAction.findPrevious) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") {
                BentoPaneAction.dispatch(BentoPaneAction.useSelectionForFind)
            }
            .keyboardShortcut("e", modifiers: .command)
            Divider()
            // ⌘T is the reflex key in every terminal, and in tmux the reflex
            // action is `prefix-c` — a new WINDOW in the session you're in. It
            // used to create a whole new session here (a heavier, rarer thing
            // that needs a name and shows up in `tmux ls`) while the everyday
            // new-window sat on ⌃⌘T. Frequency and resistance were inverted.
            Button("New tmux Window") { BentoPaneAction.dispatch(BentoPaneAction.newTmuxWindow) }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Session") { BentoTerminalWindow.newWindow() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Window (no tmux)") { BentoTerminalWindow.newWindowNoTmux() }
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])
            Divider()
            Button("Split Right (-h)") { BentoPaneAction.dispatch(BentoPaneAction.splitVertically) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down (-v)") { BentoPaneAction.dispatch(BentoPaneAction.splitHorizontally) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Select Next Pane") { BentoPaneAction.dispatch(BentoPaneAction.nextPane) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Select Previous Pane") { BentoPaneAction.dispatch(BentoPaneAction.previousPane) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Swap Pane Up") { BentoPaneAction.dispatch(BentoPaneAction.swapPaneUp) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Swap Pane Down") { BentoPaneAction.dispatch(BentoPaneAction.swapPaneDown) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Toggle Zoom") { BentoPaneAction.dispatch(BentoPaneAction.toggleZoom) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            // ⌘0..⌘9 → the window whose tmux INDEX is that digit, matching the
            // `index:name` the toolbar shows and tmux's own `prefix <n>`.
            // Tucked in a submenu; the shortcuts fire whether it's open or not.
            Menu("Select Window") {
                ForEach(0...9, id: \.self) { n in
                    Button("Window \(n)") {
                        BentoPaneAction.dispatch(BentoPaneAction.selectWindow[n])
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
            Divider()
            // Re-assert this window's grid on the shared tmux session (another
            // client, e.g. an iPad, may have shrunk the canvas).
            Button("Track Session Size to This Window") { BentoTerminalWindow.trackActiveSessionSize() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Close Pane") { BentoPaneAction.dispatch(BentoPaneAction.closePane) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { BentoTerminalWindow.closeMainWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}

/// The small set of secondary windows the app can spawn. Opened via AppKit so
/// SwiftUI Scene plumbing doesn't have to be fought for windows that appear
/// once and are dismissed.
///
/// Pair and Devices went out with the relay: there is no daemon to pair WITH,
/// and a host you reach is one you can already `ssh` to.
enum Windows {
    enum Kind { case wizard, firstRun }

    @MainActor
    static func show(_ kind: Kind, env: BentoCLI) {
        let title: String
        let content: AnyView
        switch kind {
        case .wizard:
            title = "New agent session"
            content = AnyView(AgentWizardWindow().environmentObject(env))
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
