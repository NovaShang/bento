import ActivityKit
import Foundation

/// ActivityKit attributes for the SpeakTerm Live Activity.
/// Shows when panes are awaiting input while the app is backgrounded.
struct SpeakTermActivityAttributes: ActivityAttributes {
    /// Static data that doesn't change during the activity
    struct ContentState: Codable, Hashable {
        let awaitingPaneCount: Int
        let hostName: String
        let latestPrompt: String
    }
}
