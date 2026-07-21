import Foundation

// Neutral workspace vocabulary — the view/model currency. Ids are plain
// integers, geometry comes from `LayoutTree`, and the view mode is a pure
// presentation preference.

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

    public init(id: PaneID, width: Int, height: Int, x: Int, y: Int,
                isActive: Bool, isZoomed: Bool = false,
                currentCommand: String? = nil, title: String? = nil) {
        self.id = id
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.isActive = isActive
        self.isZoomed = isZoomed
        self.currentCommand = currentCommand
        self.title = title
    }
}

/// A pane row/tab's visual status — the state aggregate plus the "done,
/// unseen" layer that isn't a `PaneState`. See `WorkspaceViewModel.paneStatus`.
public enum PaneDisplayStatus: Equatable, Sendable {
    case idle       // nothing running / seen — no accent
    case working    // an agent is running — blue
    case awaiting   // an agent needs input — amber
    case doneUnseen // an agent finished while unfocused — green (✓)
}

/// How a new pane gets seeded — the two creation paths, identical in both
/// view modes.
public enum PaneSeed: Sendable {
    /// Same working directory and start command as the current pane.
    case duplicateCurrent
    /// Explicit working directory and/or command (nil command = default agent).
    case custom(path: String?, command: String?)
}
