import SwiftUI

@main
struct BentoApp: App {
    @StateObject private var hostStore = HostStore()
    @StateObject private var sessionManager = SessionManager.shared
    @StateObject private var relayStore = RelayDaemonStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

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
            .environmentObject(hostStore)
            .environmentObject(sessionManager)
            .environmentObject(relayStore)
            .sheet(isPresented: .init(
                get: { !hasSeenOnboarding },
                set: { if !$0 { hasSeenOnboarding = true } }
            )) {
                OnboardingView()
                    .interactiveDismissDisabled(false)
            }
            .onChange(of: scenePhase) { _, newPhase in
                sessionManager.handleScenePhaseChange(newPhase)
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    /// Handles `bento://session/<hostID>` and `bento://app`.
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
        default:
            break
        }
    }
}
