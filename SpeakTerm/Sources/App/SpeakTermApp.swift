import SwiftUI

@main
struct SpeakTermApp: App {
    @StateObject private var hostStore = HostStore()
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HostListView()
            }
            .environmentObject(hostStore)
            .sheet(isPresented: .init(
                get: { !hasSeenOnboarding },
                set: { if !$0 { hasSeenOnboarding = true } }
            )) {
                OnboardingView()
                    .interactiveDismissDisabled(false)
            }
        }
    }
}
