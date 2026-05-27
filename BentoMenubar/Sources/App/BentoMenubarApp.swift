import SwiftUI

@main
struct BentoMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: appDelegate)
                .environmentObject(appDelegate.bento)
        } label: {
            // Template image — macOS tints to match dark/light menu bar.
            Image("MenubarIcon")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environmentObject(appDelegate.bento)
        }
    }
}

/// Windows manages the small set of secondary windows the menubar can spawn
/// for Pair / Wizard / Devices. We open them via AppKit so we don't fight
/// SwiftUI Scene plumbing for menubar apps (regular Window scenes need a
/// Dock icon, which we don't have).
enum Windows {
    enum Kind { case pair, wizard, devices }

    @MainActor
    static func show(_ kind: Kind, env: BentoCLI) {
        let title: String
        let content: AnyView
        switch kind {
        case .pair:
            title = "Pair iPhone"
            content = AnyView(PairingWindow().environmentObject(env))
        case .wizard:
            title = "New agent session"
            content = AnyView(AgentWizardWindow().environmentObject(env))
        case .devices:
            title = "Paired devices"
            content = AnyView(DevicesWindow().environmentObject(env))
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
