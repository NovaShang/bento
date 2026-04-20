import ActivityKit
import Foundation

/// Manages Live Activity for lock screen / Dynamic Island notifications
/// when panes are awaiting input while the app is backgrounded.
final class LiveActivityService: @unchecked Sendable {
    static let shared = LiveActivityService()
    private var currentActivity: Activity<SpeakTermActivityAttributes>?
    private var hostName: String = ""

    private init() {}

    func setHostName(_ name: String) {
        hostName = name
    }

    /// Update the Live Activity based on current pane states
    func updateActivity(awaitingCount: Int, latestPrompt: String) {
        let state = SpeakTermActivityAttributes.ContentState(
            awaitingPaneCount: awaitingCount,
            hostName: hostName,
            latestPrompt: latestPrompt
        )

        if awaitingCount > 0 {
            if currentActivity == nil {
                startActivity(state: state)
            } else {
                updateExistingActivity(state: state)
            }
        } else {
            endActivity()
        }
    }

    private func startActivity(state: SpeakTermActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        do {
            let attributes = SpeakTermActivityAttributes()
            let content = ActivityContent(state: state, staleDate: nil)
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            dlog("Live Activity started")
        } catch {
            dlog("Failed to start Live Activity: \(error)")
        }
    }

    private func updateExistingActivity(state: SpeakTermActivityAttributes.ContentState) {
        guard let activity = currentActivity else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            await activity.update(content)
        }
    }

    func endActivity() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        let finalState = SpeakTermActivityAttributes.ContentState(
            awaitingPaneCount: 0,
            hostName: hostName,
            latestPrompt: ""
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        Task {
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }
}
