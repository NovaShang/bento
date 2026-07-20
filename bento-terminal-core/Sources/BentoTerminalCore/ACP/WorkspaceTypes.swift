import Foundation

// Neutral workspace vocabulary — the view/model currency after the tmux
// era (docs/acp-first-refactor.md S4b). No tmux dialect anywhere: ids are
// plain integers, geometry comes from `LayoutTree`, and the view mode is a
// pure presentation preference.

/// Identity of one pane. Globally unique across sessions (the workspace
/// store allocates monotonically), so a bare `raw` int is unambiguous.
public struct PaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: Int
    public var description: String { "pane\(raw)" }

    public init(_ raw: Int) { self.raw = raw }
}

/// The user-facing "Parallel (tiled) | Focus (list)" view mode. A pure view
/// preference — switching never touches structure.
public enum SessionViewMode: String, Equatable, Sendable {
    case tiled, list
}

/// One pane as the views consume it: identity, cell geometry from the
/// session's layout tree, focus/zoom flags, and what it runs. Built by
/// `AgentWorkspaceStore.paneList(session:)`.
public struct Pane: Identifiable, Sendable, Hashable {
    public let id: PaneID
    public var width: Int
    public var height: Int
    public var x: Int
    public var y: Int
    public var isActive: Bool
    /// True when this pane is the session's temporarily maximized (zoomed) one.
    public var isZoomed: Bool
    /// The command the pane's agent preset runs (e.g. "opencode").
    public var currentCommand: String?
    /// Display title: user rename, else the runtime's live title, else cwd.
    public var title: String?
    /// Terminal-era mouse-reporting flags; always false for chat panes. Kept
    /// so the parked terminal surface code keeps compiling (S4c).
    public var mouseAny: Bool
    public var mouseSGR: Bool

    public init(id: PaneID, width: Int, height: Int, x: Int, y: Int,
                isActive: Bool, isZoomed: Bool = false,
                currentCommand: String? = nil, title: String? = nil,
                mouseAny: Bool = false, mouseSGR: Bool = false) {
        self.id = id
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.isActive = isActive
        self.isZoomed = isZoomed
        self.currentCommand = currentCommand
        self.title = title
        self.mouseAny = mouseAny
        self.mouseSGR = mouseSGR
    }
}

/// The session's structural shape. Windows are gone, so only two shapes are
/// reachable; the other cases survive for call-site compatibility until the
/// S4c sweep.
public enum SessionStructure: Equatable, Sendable {
    /// One pane — both view modes coincide.
    case degenerate
    /// Many panes in one layout tree.
    case tiled
}

/// A pane row/tab's visual status — the state aggregate plus the "done,
/// unseen" layer that isn't a `PaneState`. See `TerminalViewModel.paneStatus`.
public enum PaneDisplayStatus: Equatable, Sendable {
    case idle       // nothing running / seen — no accent
    case working    // an agent is running — blue
    case awaiting   // an agent needs input — amber
    case doneUnseen // an agent finished while unfocused — green (✓)
}

/// Where a cross-session move lands. Windows are gone, so there is exactly
/// one landing semantic (the target's active cell splits); the enum survives
/// for call-site compatibility.
public enum MoveLanding: Sendable, Equatable {
    case auto, joinCurrentWindow, newWindow
}

/// Outcome of a cross-session pane move.
public enum MoveResult: Sendable, Equatable {
    case moved, needsLandingChoice, failed
}

/// How a new pane gets seeded — the two creation paths, identical in both
/// view modes.
public enum PaneSeed: Sendable {
    /// Same working directory and start command as the current pane.
    case duplicateCurrent
    /// Explicit working directory and/or command (nil command = default agent).
    case custom(path: String?, command: String?)
}
