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
