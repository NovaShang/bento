import ACPHostKit
import AppKit
import BentoCore
import Foundation
import ServiceManagement
import SwiftUI

/// AppDelegate owns:
///   - the daemon's lifecycle (start on launch, SIGTERM on terminate)
///   - the background polling timer that refreshes status + sessions
///
/// Polling lives here, NOT in MenuContent, because the `MenuBarExtra` content
/// view only materializes while the menu is open. A poll loop attached to the
/// content view would freeze whenever the dropdown is closed — which is most
/// of the time.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let bento = BentoCLI()
    @Published var status: DaemonStatus?
    @Published var sessions: [SessionItem] = []
    /// Panes per session, refreshed alongside the session list so the
    /// menu's submenu can render without a per-open async fetch.
    @Published var sessionPanes: [String: [PaneItem]] = [:]
    /// The running daemon is not the one this app ships — the .app was
    /// replaced while the engine kept executing the old inode. Drives the
    /// menubar's update prompt. See `recomputeDaemonUpdatePending()`.
    @Published var daemonUpdatePending = false
    /// True while a user-confirmed engine restart is in flight, so the menu
    /// item can't be fired twice and the poll doesn't fight it.
    @Published var restartingDaemon = false

    private var pollTimer: Timer?
    /// Consecutive status polls that came back nil (daemon unreachable).
    /// launchd's KeepAlive relaunches a daemon that EXITED, but it can't see
    /// a hung one, and there's a window after a crash where the app is up but
    /// launchd hasn't relaunched yet. The poll doubles as a watchdog: a couple
    /// of missed probes and we re-run `tunnel start`, whose socket liveness
    /// check treats a wedged daemon as down and force-restarts it (bootout +
    /// bootstrap). See reviveDaemonIfDown().
    private var daemonMissCount = 0
    /// True while a watchdog revive is in flight, so overlapping 5s polls
    /// don't stack multiple `tunnel start`s.
    private var revivingDaemon = false
    /// KVO token for `NSApp.effectiveAppearance` — drives follow-system light/dark.
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the saved light/dark preference before any window appears, and
        // keep it in sync when the user changes it or (in follow-system mode) the
        // OS appearance flips.
        applyAppearanceMode()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceModeChanged),
            name: .appearanceModeChanged, object: nil)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncSystemAppearance() }
        }

        // Wire the toolbar's app-target actions (the New Agent wizard
        // and the Settings scene) into the core window code via its hooks.
        WorkspaceWindow.onNewAgentSession = { [weak self] in
            guard let self else { return }
            Windows.show(.wizard, env: self.bento)
        }
        WorkspaceWindow.onOpenSettings = {
            // Route through SwiftUI's openSettings (via MenubarLabel) — the
            // AppKit `showSettingsWindow:` selector is a no-op in MenuBarExtra apps.
            NotificationCenter.default.post(name: .bentoOpenSettings, object: nil)
        }
        // Agents are hosted by the daemon through the workspace store; wire
        // the daemon launcher in before any window can spawn one. There is no
        // in-process fallback: if the daemon is down a launch fails loudly
        // (AcpHostError.daemonNotRunning) rather than silently spawning an
        // agent that can't persist or reach the phone. The daemon is started
        // on launch below and can be retried from the first-run window.
        AcpPaneModule.install(on: AgentWorkspaceStore.shared)
        // Hand shell chrome (preview dock, native directory panel) to the
        // modules that must not import it — before any window exists.
        ShellMacWiring.install()
        AgentWorkspaceStore.shared.launcher = DaemonAgentLauncher()
        // The workspace toolbar's Sessions button reuses the menubar's SwiftUI
        // session list verbatim (via NSHostingMenu) so the two behave identically.
        // NSHostingMenu is macOS 14.4+; older systems get a flat clickable list.
        WorkspaceWindow.sessionsMenuProvider = { [weak self] in
            guard let self else { return nil }
            if #available(macOS 14.4, *) {
                return NSHostingMenu(rootView: SessionsMenuView(app: self))
            }
            return self.flatSessionsMenu()
        }

        // Opt-in telemetry (no-op unless the user enabled the Settings toggle):
        // count today as an active day, and route batches through the same
        // relay the daemon uses if the user configured a custom one.
        let configuredRelay = bento.currentRelayURL()
        if !configuredRelay.isEmpty {
            TelemetryService.relayBaseURLOverride = configuredRelay
        }
        TelemetryService.shared.appBecameActive()

        Task { [weak self] in
            guard let self else { return }
            try? await self.bento.startDaemon(relay: nil)
            // Structure follows the daemon (statekv): adopt its workspace
            // tree, seed it with ours on first contact, reconcile instances.
            await AgentWorkspaceStore.shared.syncWithDaemon()
            await self.refresh()
            self.startPolling()
            // First launch → the onboarding wizard owns the stage (design doc
            // §4.1): environment checklist, first workspace, first voice
            // command, pairing hand-off. BENTO_FORCE_FIRST_RUN=1 re-triggers
            // it for testing without clearing defaults.
            // Test hook: open a specific secondary window directly
            // (BENTO_OPEN_WINDOW=pair|wizard|devices|firstRun), for
            // screenshot-driven verification without UI scripting.
            if let name = ProcessInfo.processInfo.environment["BENTO_OPEN_WINDOW"] {
                switch name {
                case "pair": Windows.show(.pair, env: self.bento)
                case "wizard": Windows.show(.wizard, env: self.bento)
                case "devices": Windows.show(.devices, env: self.bento)
                default: Windows.show(.firstRun, env: self.bento)
                }
                return
            }
            let firstRunPending = !UserDefaults.standard.bool(forKey: FirstRunWindow.completedKey)
                || ProcessInfo.processInfo.environment["BENTO_FORCE_FIRST_RUN"] == "1"
            if firstRunPending {
                Windows.show(.firstRun, env: self.bento)
                return
            }
            // Open the terminal window on a user-initiated launch (done after the
            // daemon is up so hosted sessions are ready). When the app is
            // started at login the menubar lives quietly in the background — the
            // user opens the window by clicking the icon (applicationShouldHandleReopen).
            if !LoginItem.isEnabled {
                WorkspaceWindow.openMainWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TelemetryService.shared.flush()
        // Detach only — the daemon OWNS
        // the agent processes, so quitting the app must NOT kill it. That is
        // exactly how sessions outlive the app; stop it explicitly with
        // `bento tunnel stop` when you really mean it.
        AgentWorkspaceStore.shared.shutdownAll()
    }

    /// Clicking the app icon while the menubar app is already running (Dock,
    /// Launchpad, or re-launching the .app) → open/focus the terminal window with
    /// the last session, creating the default session if there was none.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        WorkspaceWindow.openMainWindow()
        return true
    }

    // MARK: - Appearance (light / dark / follow-system)

    /// Pin (or release, for follow-system) the app's appearance from the user's
    /// preference. Setting `NSApp.appearance` flips every AppKit/SwiftUI semantic
    /// color for free; the pane chrome recolors via `.terminalThemeChanged`.
    private func applyAppearanceMode() {
        switch ThemeStore.shared.appearanceMode {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        syncSystemAppearance()
    }

    @objc private func appearanceModeChanged() { applyAppearanceMode() }

    /// Push the OS's resolved light/dark into the shared store (only changes the
    /// effective theme while in follow-system mode).
    private func syncSystemAppearance() {
        ThemeStore.shared.updateSystemIsDark(ThemeStore.detectSystemIsDark())
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // User is looking at the app now — clear the awaiting Dock badge.
        MacAwaitingNotifier.shared.clearBadge()
        TelemetryService.shared.appBecameActive()
    }

    /// Menubar (accessory) app: never auto-quit just because a terminal window
    /// closed — the app lives as long as the menubar item does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Backs the native tab bar's `+` button: open a brand-new session as a
    /// tab. The responder chain reaches the app delegate for our session windows
    /// (which have no NSWindowController), and implementing this is also what
    /// makes the `+` button appear on the tab bar in the first place.
    @objc func newWindowForTab(_ sender: Any?) {
        WorkspaceWindow.newSessionTab()
    }

    /// Flat fallback for macOS < 14.4 (no NSHostingMenu): each session is a
    /// directly-clickable item that attaches it. The first level is still
    /// clickable, just without the per-session windows/rename/kill submenu.
    private func flatSessionsMenu() -> NSMenu {
        let menu = NSMenu()
        if sessions.isEmpty {
            let item = NSMenuItem(title: "No workspaces", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let open = WorkspaceWindow.openSessionKeys
        for s in sessions {
            let item = NSMenuItem(title: "\(s.name)  ·  \(relativeActivity(s.lastActivity))",
                                  action: #selector(attachSessionFlat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.name
            item.image = NSImage(systemSymbolName: open.contains(s.name) ? "eye.fill" : "eye.slash",
                                 accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func attachSessionFlat(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        WorkspaceWindow.focusOrOpen(session: name)
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
        reviveDaemonIfDown()
        recomputeDaemonUpdatePending()
        // Sessions and panes come straight from the workspace store (no
        // shell-outs) — it is the single source of truth for structure.
        let overview = AgentWorkspaceStore.shared.overview
        sessions = overview.map {
            SessionItem(name: $0.name, lastActivity: $0.lastActivity)
        }
        // Drive the terminal window's tab strip with the full session list.
        WorkspaceWindow.setServerSessions(overview.map(\.name))
        var fresh: [String: [PaneItem]] = [:]
        for s in overview {
            fresh[s.name] = s.panes.map {
                PaneItem(session: s.name, index: $0.index, name: $0.name,
                         active: $0.active)
            }
        }
        sessionPanes = fresh
    }

    /// Watchdog half of the status poll: keep the daemon alive, don't just
    /// display its state. launchd relaunches a daemon that exited; this covers
    /// the two cases it can't — a hung (still-running) daemon, and the gap
    /// between a crash and launchd's relaunch while the app is foregrounded.
    /// `startDaemon` → `tunnel start` probes the daemon socket (500ms) and,
    /// finding it unreachable, force-restarts via bootout + bootstrap.
    private func reviveDaemonIfDown() {
        // A user-confirmed engine swap takes the daemon down on purpose, and
        // `restartDaemon` brings it back itself. Without this the watchdog
        // would race its own app's `tunnel stop`.
        guard !restartingDaemon else {
            daemonMissCount = 0
            return
        }
        guard status == nil else {
            daemonMissCount = 0
            return
        }
        daemonMissCount += 1
        // ~10s of continuous silence (2 polls @5s) before acting, so a
        // transient blip or a daemon mid-restart isn't force-cycled.
        guard daemonMissCount >= 2, !revivingDaemon else { return }
        revivingDaemon = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.bento.startDaemon(relay: nil)
            self.revivingDaemon = false
            self.daemonMissCount = 0
        }
    }

    // MARK: - Engine (daemon) updates

    /// Decide whether the menubar should offer an engine restart.
    ///
    /// Replacing "Bento ACP.app" rewrites the embedded `bento-daemon`, but the
    /// running daemon goes on executing the old inode and `tunnel start`
    /// no-ops while it is alive — so without this check a user runs a new app
    /// against an old engine until they happen to reboot. We compare binary
    /// hashes rather than version strings because every local build reports
    /// the same version, which would make the check permanently blind.
    ///
    /// A daemon that reports no hash at all is treated as stale: it predates
    /// this field, so it is by definition older than the app asking. The one
    /// case we stay silent on is not knowing our own answer — if the helper
    /// we would launch can't be hashed, nagging would be guessing.
    private func recomputeDaemonUpdatePending() {
        guard !restartingDaemon, let status else {
            daemonUpdatePending = false
            return
        }
        guard let target = bento.targetDaemonHash() else {
            daemonUpdatePending = false
            return
        }
        daemonUpdatePending = status.exeHash != target
    }

    /// Ask, then swap the engine. The confirmation names the cost in the
    /// user's own terms — how many agents die — because that is the entire
    /// reason this isn't automatic.
    func confirmAndRestartDaemon() {
        guard !restartingDaemon else { return }
        let live = status?.liveAgents ?? 0
        let busy = status?.busyAgents ?? 0

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Restart the Bento engine?"
        alert.informativeText = Self.restartCost(live: live, busy: busy)
        alert.addButton(withTitle: "Restart engine")
        alert.addButton(withTitle: "Not now")
        // Destructive when work is actually at stake; a plain choice when not.
        if live > 0 { alert.buttons.first?.hasDestructiveAction = true }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        restartingDaemon = true
        daemonUpdatePending = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.bento.restartDaemon()
                // Same reattach the app does on launch: the fresh daemon has
                // no agents, so the workspace tree has to be re-seeded rather
                // than left describing processes that no longer exist.
                await AgentWorkspaceStore.shared.syncWithDaemon()
            } catch {
                self.presentRestartFailure(error)
            }
            self.restartingDaemon = false
            await self.refresh()
        }
    }

    /// Spell out what a restart costs. Zero live agents is the common case
    /// right after an update and deserves to read as harmless, because it is.
    static func restartCost(live: Int, busy: Int) -> String {
        guard live > 0 else {
            return "No agents are running, so nothing will be interrupted. "
                + "This swaps in the engine that shipped with this version of Bento."
        }
        let agents = "\(live) running agent session\(live == 1 ? "" : "s")"
        let midTurn = busy > 0 ? " \(busy) of them \(busy == 1 ? "is" : "are") mid-turn." : ""
        return "This ends \(agents) — their processes are hosted by the engine "
            + "and cannot survive it.\(midTurn) Your conversation history is kept."
    }

    private func presentRestartFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't restart the engine"
        alert.informativeText = "\(error.localizedDescription)\n\n"
            + "The old engine may still be running. You can retry, or run "
            + "`bento tunnel stop && bento tunnel start` in Terminal."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func sendSIGTERMToDaemon() {
        let home: URL
        if let env = ProcessInfo.processInfo.environment["BENTO_HOME"] {
            home = URL(fileURLWithPath: env)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".bento-acp")
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
