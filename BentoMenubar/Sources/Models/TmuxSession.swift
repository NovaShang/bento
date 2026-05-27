import Foundation

/// One row of `tmux list-sessions`.
struct TmuxSession: Identifiable, Hashable {
    let name: String
    let attached: Bool
    /// Last time anything happened in the session (output, keystroke, attach).
    /// Falls back to `Date.distantPast` if tmux didn't return it.
    let lastActivity: Date

    var id: String { name }
}
