import SwiftUI
import UIKit
import BentoCore
import BentoShelliOS

@main
struct BentoApp: App {
    @StateObject private var sessionManager = SessionManager.shared
    @StateObject private var relayStore = RelayDaemonStore()
    @StateObject private var themeStore = ThemeStore.shared
    @Environment(\.scenePhase) private var scenePhase

    /// SwiftUI scheme to force, from the appearance preference (nil = follow OS).
    private var preferredScheme: ColorScheme? {
        switch themeStore.appearanceMode {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    init() {
        BentoAppearance.install()
        // Composition root: teach the generic shell how product A resolves a
        // store (paired relay + ACP pane module) and how it builds a pane VC
        // (the ACP chat). A terminal / file / browser pane installs its own.
        SessionManager.shared.storeProvider = { host, _ in SessionManager.acpStore(for: host) }
        // Bento Agents reaches a Mac through the paired daemon, so the `+`
        // button asks for a pairing code.
        ShellPaneRegistry.hostAddOptions = [
            HostAddOption(id: "pair", title: "Pair a Mac…", systemImage: "desktopcomputer") { dismiss in
                AnyView(RelayPairView(prefill: nil))
            },
        ]
        ShellPaneRegistry.paneControllerFactory = { AgentChatVC(store: $0) }
        ShellPaneRegistry.previewContextProvider = { store, id in
            store.agentRuntime(forPane: id.raw)?.makePreviewContext(hostLabel: "Mac")
        }
        Self.logBundledFonts()
        // Mirror the core package's dlog (reconnect loop, session events, voice
        // session — os_log only by default) into Documents/debug.log, so a
        // real-device incident is fully diagnosable from one file pull:
        //   xcrun devicectl device copy from --domain-type appDataContainer
        //     --domain-identifier com.bento.app --source Documents/debug.log …
        coreDlogFileSink = { DebugLogger.shared.log($0) }
    }

    private static func logBundledFonts() {
        let expected = ["JetBrainsMono-Regular", "MapleMono-NF-CN-Regular"]
        for name in expected {
            if UIFont(name: name, size: 14) != nil {
                NSLog("[Bento.fonts] OK loaded: %@", name)
            } else {
                NSLog("[Bento.fonts] MISSING: %@", name)
            }
        }
        let monoFamilies = UIFont.familyNames
            .filter { $0.localizedCaseInsensitiveContains("maple") || $0.localizedCaseInsensitiveContains("jetbrains") }
        NSLog("[Bento.fonts] matching families: %@", monoFamilies.joined(separator: ", "))
        for fam in monoFamilies {
            NSLog("[Bento.fonts]   %@ -> %@", fam, UIFont.fontNames(forFamilyName: fam).joined(separator: ", "))
        }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $sessionManager.navigationPath) {
                HostListView()
                    .navigationDestination(for: HostNavigation.self) { dest in
                        switch dest {
                        case .sessions(let host):
                            HostSessionsView(host: host)
                        }
                    }
            }
            .environmentObject(sessionManager)
            .environmentObject(relayStore)
            .preferredColorScheme(preferredScheme)
            .modifier(SystemAppearanceSync())
            .tint(Color.bentoEmerald)
            .onChange(of: scenePhase) { _, newPhase in
                sessionManager.handleScenePhaseChange(newPhase)
                // Opt-in telemetry lifecycle: count the active day on
                // foreground, flush the buffered batch on background.
                // Both are no-ops unless the user enabled the toggle.
                switch newPhase {
                case .active: TelemetryService.shared.appBecameActive()
                case .background: TelemetryService.shared.flush()
                default: break
                }
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    /// Handles `bento://session/<hostID>`, `bento://app`, and
    /// `bento://pair?d=<daemonID>&c=<code>&l=<label>` (deep link emitted by
    /// the Mac PairingWindow QR code).
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "bento-acp" else { return }
        let host = url.host ?? ""
        let path = url.pathComponents
        switch host {
        case "session":
            guard let idString = path.dropFirst().first,
                  let uuid = UUID(uuidString: idString),
                  let entry = sessionManager.activeSessions.first(where: { $0.key.hostID == uuid }) else {
                return
            }
            sessionManager.navigationPath = [.sessions(entry.host)]
        case "app":
            sessionManager.navigationPath = []
        case "pair":
            handlePairDeepLink(url)
        default:
            break
        }
    }

    private func handlePairDeepLink(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = comps.queryItems ?? []
        let daemonID = items.first(where: { $0.name == "d" })?.value ?? ""
        let rawCode = items.first(where: { $0.name == "c" })?.value ?? ""
        let code = String(rawCode.filter(\.isNumber).prefix(6))
        let label = items.first(where: { $0.name == "l" })?.value
        guard !daemonID.isEmpty, code.count == 6 else { return }
        sessionManager.navigationPath = []
        relayStore.pendingPair = PendingRelayPair(daemonID: daemonID, code: code, label: label)
    }
}

/// Mirrors the effective light/dark into the shared ThemeStore so the terminal
/// surface (not a UIColor-backed view) resolves the right theme slot. `colorScheme`
/// in a modifier is fully reactive, so this fires both on first appearance and on
/// every OS / preference flip.
private struct SystemAppearanceSync: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content
            .onAppear { ThemeStore.shared.updateSystemIsDark(colorScheme == .dark) }
            .onChange(of: colorScheme) { _, scheme in
                ThemeStore.shared.updateSystemIsDark(scheme == .dark)
            }
    }
}
