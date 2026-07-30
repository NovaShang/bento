import AppKit
import BentoShellTermMac
import BentoFoundation
import BentoMenuKit
import BentoTerminalPane
import BentoUI
import Foundation
import ServiceManagement
import SwiftUI

/// AppDelegate owns app-lifetime concerns: appearance, the terminal window's
/// app-target hooks, and quitting when the last window closes.
///
/// It no longer starts a daemon. Bento Term leaves nothing running on any
/// machine — the tmux server it drives is the user's own, and outliving the
/// app is that server's job, not ours.
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

        // Wire the terminal toolbar's app-target actions (the New Agent wizard
        // and the Settings scene) into the core window code via its hooks.
        BentoTerminalWindow.onNewAgentSession = { [weak self] in
            guard let self else { return }
            Windows.show(.wizard, env: self.bento)
        }
        BentoTerminalWindow.onOpenSettings = {
            // Click the Settings item SwiftUI installed, rather than guessing
            // the selector behind it.
            //
            // `showSettingsWindow:` / `showPreferencesWindow:` is the usual
            // advice and it does nothing here — the name has moved across
            // releases and nothing in the responder chain answered either. The
            // menu item is the one thing guaranteed to be wired correctly,
            // because SwiftUI wired it: it is what ⌘, already triggers.
            NSApp.activate(ignoringOtherApps: true)
            guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
            let index = appMenu.indexOfItem(withTitle: "Settings…")
            if index >= 0 {
                appMenu.performActionForItem(at: index)
                return
            }
            // Fall back to the ⌘, item by shortcut, in case the title is
            // localized or renamed.
            if let comma = appMenu.items.firstIndex(where: {
                $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
            }) {
                appMenu.performActionForItem(at: comma)
            }
        }
        // Kill a session reliably via a one-shot `tmux kill-session`, then refresh
        // so the strip reflects it immediately (don't wait for the 5s poll).
        BentoTerminalWindow.killSessionCLI = { [weak self] name in
            Task { @MainActor in
                try? await TmuxCLI.kill(session: name)
                await self?.refresh()
            }
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
            await self.refresh()
            self.startPolling()
            // First launch → the onboarding wizard owns the stage (design doc
            // §4.1): environment checklist, first workspace, first voice
            // command, pairing hand-off. BENTO_FORCE_FIRST_RUN=1 re-triggers
            // it for testing without clearing defaults.
            // Test hook: open a specific window directly
            // (BENTO_OPEN_WINDOW=wizard|plain|main|firstRun), for
            // screenshot-driven verification without UI scripting.
            TestHooks.installIfRequested()
            if let name = ProcessInfo.processInfo.environment["BENTO_OPEN_WINDOW"] {
                switch name {
                case "wizard": Windows.show(.wizard, env: self.bento)
                case "plain": BentoTerminalWindow.newWindowNoTmux()
                case "main": BentoTerminalWindow.openMainWindow()
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
            // A window IS the app now — there is no menu bar to live quietly
            // in, so launching always opens one.
            BentoTerminalWindow.openMainWindow()
        }
    }

    /// Quitting takes down the GUI, NOT the background service.
    ///
    /// This used to SIGTERM the daemon on the way out, which welded the two
    /// lifecycles together and defeated the point of having a daemon at all:
    /// the relay exists so the phone can reach this Mac while nobody is sitting
    /// at it. Quit the window half and the phone lost the Mac with it. The
    /// daemon is a separate, launchd-managed process now — the menubar is its
    /// control surface, not its container, and "Stop background service" is how
    /// you shut it down on purpose.
    func applicationWillTerminate(_ notification: Notification) {
        TelemetryService.shared.flush()
    }

    /// No confirmation here (see the note further down) — this exists only to
    /// mark the quit BEFORE any window closes, so the reopen list records the
    /// set that was open instead of watching it drain one tab at a time.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        BentoTerminalWindow.isTerminating = true
        return .terminateNow
    }

    /// Clicking the app icon while the menubar app is already running (Dock,
    /// Launchpad, or re-launching the .app) → open/focus the terminal window with
    /// the last session, creating the default session if there was none.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        BentoTerminalWindow.openMainWindow()
        return true
    }

    /// `bento-term://…` — the launch ABI a resident menu process (and
    /// `open(1)`, and any script) uses to reach this app: it works whether or
    /// not we are already running, and Launch Services resolves the app by
    /// scheme rather than by a path that can go stale.
    /// See docs/menubar-unification.md §4.1.
    ///
    /// A URL is untrusted input, so the router only ever yields the two things
    /// a user could do by clicking: show the app, or focus a named session.
    /// Anything else parses to nil and we do nothing at all — not even
    /// activate, so a malformed link can't even steal focus. Opening a session
    /// goes through the in-app window (`focusOrOpen`), never `TmuxCLI.attach`,
    /// which may hand the session to whatever external terminal the user
    /// prefers — a URL aimed at this app should land in this app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let route = BentoURLRouter.route(url, scheme: .term) else { continue }
            NSApp.activate(ignoringOtherApps: true)
            switch route {
            case .open:
                BentoTerminalWindow.openMainWindow()
            case .openSession(let name):
                BentoTerminalWindow.focusOrOpen(session: name)
            }
        }
    }

    // MARK: - Appearance (light / dark / follow-system)

    /// Pin (or release, for follow-system) the app's appearance from the user's
    /// preference. Setting `NSApp.appearance` flips every AppKit/SwiftUI semantic
    /// color for free; the ghostty pane chrome recolors via `.terminalThemeChanged`.
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

    // There is deliberately NO `applicationShouldTerminate` confirmation, and we
    // deliberately do not call libghostty's `ghostty_surface_needs_confirm_quit`
    // / `ghostty_app_needs_confirm_quit`.
    //
    // Those exist for a terminal that OWNS its processes: quitting kills them, so
    // it has to ask. Bento is a tmux client. Quitting is a detach — the session,
    // its windows, its panes and everything running in them survive on the
    // server, and `tmux attach` (or reopening Bento) brings them right back.
    // Prompting "there are processes still running" would teach the user to fear
    // an action that is lossless, which is worse than not prompting at all.
    //
    // The only surfaces this would be honest for are the non-tmux ones (New →
    // Other), and they are not worth a modal on the way out. Revisit only if
    // non-tmux panes become a real part of the product.

    /// Backs the native tab bar's `+` button: open a brand-new tmux session as a
    /// tab. The responder chain reaches the app delegate for our session windows
    /// (which have no NSWindowController), and implementing this is also what
    /// makes the `+` button appear on the tab bar in the first place.
    @objc func newWindowForTab(_ sender: Any?) {
        BentoTerminalWindow.newSessionTab()
    }


    @objc private func attachSessionFlat(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Task { try? await TmuxCLI.attach(session: name) }
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
        // Drive the terminal window's tab strip with the full session list.
        BentoTerminalWindow.setServerSessions(sessions.map(\.name))
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
