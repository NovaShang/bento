import AppKit
import BentoTerminalCore
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
    /// Windows per session, fetched alongside the session list so the
    /// menu's submenu can render without a per-open async fetch (NSMenu
    /// would already be on screen by the time tmux replied).
    @Published var tmuxWindows: [String: [TmuxWindow]] = [:]

    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.bento.startDaemon(relay: nil)
            await self.refresh()
            self.startPolling()
            // Reopen last run's terminal sessions (no-op unless the user enabled
            // it). Done after the daemon is up so the local tmux server is ready.
            BentoTerminalWindow.reopenLastSessionsIfEnabled()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sendSIGTERMToDaemon()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // User is looking at the app now — clear the awaiting Dock badge.
        MacAwaitingNotifier.shared.clearBadge()
    }

    /// Menubar (accessory) app: never auto-quit just because a terminal window
    /// closed — the app lives as long as the menubar item does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        let sessions = await TmuxCLI.listSessions()
        tmuxSessions = sessions
        // Fan-out the per-session window queries concurrently. Each call
        // is a single `tmux list-windows` shell-out (a few ms), so even
        // with many sessions this finishes well under the 5s poll period.
        var fresh: [String: [TmuxWindow]] = [:]
        await withTaskGroup(of: (String, [TmuxWindow]).self) { group in
            for s in sessions {
                group.addTask { (s.name, await TmuxCLI.listWindows(session: s.name)) }
            }
            for await (name, wins) in group {
                fresh[name] = wins
            }
        }
        tmuxWindows = fresh
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
