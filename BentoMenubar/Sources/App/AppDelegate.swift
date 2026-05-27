import AppKit
import Foundation
import ServiceManagement

/// AppDelegate owns:
///   - the daemon's lifecycle (start on launch, SIGTERM on terminate)
///   - the background polling timer that refreshes status + tmux sessions
///
/// Polling lives here, NOT in MenuContent, because the `MenuBarExtra` content
/// view only materializes while the menu is open. A poll loop attached to the
/// content view would freeze whenever the dropdown is closed — which is most
/// of the time.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let bento = BentoCLI()
    @Published var status: DaemonStatus?
    @Published var tmuxSessions: [TmuxSession] = []

    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.bento.startDaemon(relay: nil)
            await self.refresh()
            self.startPolling()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sendSIGTERMToDaemon()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        status = await bento.status()
        tmuxSessions = await TmuxCLI.listSessions()
    }

    private func sendSIGTERMToDaemon() {
        let home: URL
        if let env = ProcessInfo.processInfo.environment["BENTO_HOME"] {
            home = URL(fileURLWithPath: env)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".bento")
        }
        let pidPath = home.appendingPathComponent("daemon.pid")
        guard let txt = try? String(contentsOf: pidPath, encoding: .utf8),
              let pid = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        kill(pid, SIGTERM)
    }
}

/// LoginItem wraps the macOS 13+ Service Management API so the toggle in
/// Settings stays a one-liner from the View side.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
