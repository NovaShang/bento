import SwiftUI

@main
struct SpeakTermApp: App {
    @StateObject private var hostStore = HostStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HostListView()
            }
            .environmentObject(hostStore)
        }
    }
}
