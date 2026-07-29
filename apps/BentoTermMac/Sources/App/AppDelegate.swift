import AppKit
import BentoShellTermMac
import BentoFoundation
import BentoUI
import Foundation
import ServiceManagement
import SwiftUI

/// AppDelegate owns:
///   - starting the trunk daemon on launch (stopping it is explicit)
///   - the term shell install (pane module + window hooks)
///   - a lightweight daemon-status poll (the tmux SESSION structure now streams
///     from the daemon's statekv mirror — see TermWorkspaceModel — so there is
///     no TmuxCLI `list-sessions` poll anymore; that retired with the SSH/tmux
///     CLI stack).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let bento = BentoCLI()
    @Published var status: DaemonStatus?

    private var pollTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearanceMode()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceModeChanged),
            name: .appearanceModeChanged, object: nil)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncSystemAppearance() }
        }

        // Register the tmux pane module on the term store + resolve the daemon
        // socket (the transport factory reads it per pane).
        TermShell.install()

        // Wire the term toolbar's app-target actions into the shell.
        BentoTermWindow.onNewAgentSession = { [weak self] in
            guard let self else { return }
            Windows.show(.wizard, env: self.bento)
        }
        BentoTermWindow.onOpenSettings = {
            NotificationCenter.default.post(name: .bentoOpenSettings, object: nil)
        }

        let configuredRelay = bento.currentRelayURL()
        if !configuredRelay.isEmpty {
            TelemetryService.relayBaseURLOverride = configuredRelay
        }
        TelemetryService.shared.appBecameActive()

        Task { [weak self] in
            guard let self else { return }
            try? await self.bento.startDaemon(relay: nil)
            await self.refresh()
            self.startPolling()

            // Test hook: open a specific secondary window directly.
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
            if !LoginItem.isEnabled {
                BentoTermWindow.openMainWindow()
            }
        }
    }

    /// Quitting takes down the GUI, NOT the background service (it is launchd-
    /// managed; the relay must reach this Mac while nobody is at it).
    func applicationWillTerminate(_ notification: Notification) {
        TelemetryService.shared.flush()
    }

    /// Mark the quit BEFORE any window closes, so the reopen list records the
    /// whole set instead of watching it drain one tab at a time.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        BentoTermWindow.isTerminating = true
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        BentoTermWindow.openMainWindow()
        return true
    }

    // MARK: - Appearance (light / dark / follow-system)

    private func applyAppearanceMode() {
        switch ThemeStore.shared.appearanceMode {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        syncSystemAppearance()
    }

    @objc private func appearanceModeChanged() { applyAppearanceMode() }

    private func syncSystemAppearance() {
        ThemeStore.shared.updateSystemIsDark(ThemeStore.detectSystemIsDark())
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        TelemetryService.shared.appBecameActive()
    }

    /// Menubar (accessory) app: never auto-quit just because a term window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Bento Term is a tmux client — quit is a lossless DETACH — so there is
    // deliberately no "processes still running" confirmation on the way out.

    /// Backs the native tab bar's `+` button. Our session windows have no
    /// NSWindowController, so the responder chain reaches the app delegate;
    /// implementing this is also what makes the `+` appear.
    @objc func newWindowForTab(_ sender: Any?) {
        BentoTermWindow.newSessionTab()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        status = await bento.status()
    }
}

/// LoginItem wraps the macOS 13+ Service Management API so the Settings toggle
/// stays a one-liner from the View side.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
