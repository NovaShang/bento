import SwiftUI
import AppKit
import BentoShellTermMac

/// MenuContent is the children of a MenuBarExtra with `.menuBarExtraStyle(.menu)`.
/// It is the face of the RESIDENT half — daemon status, pairing, and the way
/// back into a window. Everything about a session lives in the window itself.
///
/// The machine-wide "Sessions" submenu the frozen product carried is gone with
/// the TmuxCLI poll: session structure now streams from the daemon's statekv
/// mirror into the window (TermWorkspaceModel). A daemon multi-target session
/// switcher is the follow-up that would repopulate it (flagged).
struct MenuContent: View {
    @EnvironmentObject var bento: BentoCLI
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var app: AppDelegate

    var body: some View {
        // An accessory app has no Dock icon, so with every window closed this is
        // the way back in.
        Button(action: { BentoTermWindow.openMainWindow() }) {
            Label("Open Bento Term", systemImage: "macwindow")
        }
        .keyboardShortcut("o")

        Divider()

        Button(action: {}) {
            Label(statusLine, systemImage: statusSymbol)
        }
        .disabled(true)

        if let id = app.status?.daemonID {
            Button(action: {}) {
                Label("daemon \(id.prefix(8))…", systemImage: "terminal")
            }
            .disabled(true)
        }

        if app.status == nil {
            Button(action: {
                Task { try? await bento.startDaemon(relay: nil); await app.refresh() }
            }) {
                Label("Start background service", systemImage: "play.circle")
            }
            Button(action: {}) {
                Label("Needed to pair and reach your phone", systemImage: "info.circle")
            }
            .disabled(true)
        }

        if app.status != nil {
            Button(action: {
                Task { try? await bento.stopDaemon(); await app.refresh() }
            }) {
                Label("Stop background service", systemImage: "stop.circle")
            }
        }

        Divider()

        Button(action: { Windows.show(.pair, env: bento) }) {
            Label("Pair new iPhone…", systemImage: "iphone.and.arrow.right.outward")
        }
        .keyboardShortcut("p")
        .disabled(app.status == nil)

        Button(action: { Windows.show(.devices, env: bento) }) {
            Label("Paired devices…", systemImage: "lock.iphone")
        }
        .disabled(app.status == nil)

        Divider()

        Button(action: {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }) {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Divider()

        Button(action: { NSApp.terminate(nil) }) {
            Label("Quit Bento", systemImage: "power")
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard let s = app.status else { return "Daemon not running" }
        if s.relayConnected {
            return "Connected · \(s.pairedDevices) device\(s.pairedDevices == 1 ? "" : "s")"
        }
        return "Daemon up · relay offline"
    }

    private var statusSymbol: String {
        guard let s = app.status else { return "xmark.circle" }
        return s.relayConnected ? "wifi" : "wifi.exclamationmark"
    }
}
