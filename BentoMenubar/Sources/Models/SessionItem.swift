import Foundation

/// One row of the menubar's session list — a session in the ACP workspace
/// store. Whether it's open as a tab in the terminal window is looked up
/// live via `BentoTerminalWindow.openSessionKeys`.
struct SessionItem: Identifiable, Hashable {
    let name: String
    /// Last time anything happened in the session. Falls back to
    /// `Date.distantPast` when unknown.
    let lastActivity: Date

    var id: String { name }
}

/// One pane row in a session's submenu (ordinals match ⌘1-9).
struct PaneItem: Identifiable, Hashable {
    /// Owning session — pane indices repeat across sessions.
    let session: String
    /// Position in the session's layout order (0-based).
    let index: Int
    let name: String
    let active: Bool

    /// Scoped so a (session, index) pair is unique across the whole list.
    var id: String { "\(session):\(index)" }
}
