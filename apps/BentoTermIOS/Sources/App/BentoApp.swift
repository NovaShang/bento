import SwiftUI
import UIKit
import BentoShelliOS
import BentoUI
import BentoFoundation

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
        // Composition root: product B is the tmux twin of product A. Teach the
        // shared shell how to resolve a tmux-backed store (paired relay,
        // TmuxPaneModule installed) and how to build a tmux pane VC.
        TmuxShell.install()
        SessionManager.shared.storeProvider = { TmuxShell.store(for: $0, session: $1) }
        Self.logBundledFonts()
        // Mirror the core package's dlog into Documents/debug.log for on-device
        // diagnosis (see the A app for the pull command).
        coreDlogFileSink = { DebugLogger.shared.log($0) }
    }

    private static func logBundledFonts() {
        let expected = ["JetBrainsMono-Regular", "MapleMono-NF-CN-Regular"]
        for name in expected where UIFont(name: name, size: 14) == nil {
            NSLog("[Bento.fonts] MISSING: %@", name)
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
                switch newPhase {
                case .active: TelemetryService.shared.appBecameActive()
                case .background: TelemetryService.shared.flush()
                default: break
                }
            }
            .onOpenURL { url in handleDeepLink(url) }
        }
    }

    /// Handles `bento://session/<hostID>`, `bento://app`, and
    /// `bento://pair?d=<daemonID>&c=<code>&l=<label>` (deep link emitted by the
    /// Mac PairingWindow QR code). Product B keeps the `bento://` scheme.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "bento" else { return }
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
/// surface (not a UIColor-backed view) resolves the right theme slot.
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
