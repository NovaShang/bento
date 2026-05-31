import Foundation

// MARK: - tmux ID Types

/// tmux session ID, e.g. "$0"
public struct TmuxSessionID: Hashable, Codable, CustomStringConvertible, Sendable {
    public let raw: Int
    public var description: String { "$\(raw)" }

    public init(_ raw: Int) { self.raw = raw }

    public init?(string: String) {
        guard string.hasPrefix("$"), let num = Int(string.dropFirst()) else { return nil }
        self.raw = num
    }
}

/// tmux window ID, e.g. "@5"
public struct TmuxWindowID: Hashable, Codable, CustomStringConvertible, Sendable {
    public let raw: Int
    public var description: String { "@\(raw)" }

    public init(_ raw: Int) { self.raw = raw }

    public init?(string: String) {
        guard string.hasPrefix("@"), let num = Int(string.dropFirst()) else { return nil }
        self.raw = num
    }
}

/// tmux pane ID, e.g. "%3"
public struct TmuxPaneID: Hashable, Codable, CustomStringConvertible, Sendable {
    public let raw: Int
    public var description: String { "%\(raw)" }

    public init(_ raw: Int) { self.raw = raw }

    public init?(string: String) {
        guard string.hasPrefix("%"), let num = Int(string.dropFirst()) else { return nil }
        self.raw = num
    }
}

// MARK: - Notifications

/// Parsed tmux control mode notifications.
public enum TmuxNotification: Sendable {
    case output(pane: TmuxPaneID, data: Data)
    case layoutChange(window: TmuxWindowID, layout: String)
    case windowAdd(window: TmuxWindowID)
    case windowClose(window: TmuxWindowID)
    case windowRenamed(window: TmuxWindowID, name: String)
    case sessionChanged(session: TmuxSessionID, name: String)
    case sessionRenamed(name: String)
    case paneModeChanged(pane: TmuxPaneID, mode: String)
    case exit(reason: String?)
}

/// A command response block from tmux. `output` is the joined text between
/// the `%begin` and `%end`/`%error` markers; `isError` is true when the block
/// terminated with `%error`.
public struct TmuxCommandResponse: Sendable {
    public let commandNumber: Int
    public let isError: Bool
    public let output: String

    public init(commandNumber: Int, isError: Bool, output: String) {
        self.commandNumber = commandNumber
        self.isError = isError
        self.output = output
    }
}

// MARK: - Layout

/// Parsed pane position+size from a tmux layout string (not used by all
/// callers; primary path is `list-panes -F` parsing instead).
public struct TmuxPaneLayout: Sendable, Hashable {
    public let paneID: TmuxPaneID
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(paneID: TmuxPaneID, x: Int, y: Int, width: Int, height: Int) {
        self.paneID = paneID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Models

public struct TmuxWindow: Identifiable, Sendable, Hashable {
    public let id: TmuxWindowID
    public var name: String
    public var panes: [Pane]
    public var layout: String?

    public init(id: TmuxWindowID, name: String, panes: [Pane], layout: String?) {
        self.id = id
        self.name = name
        self.panes = panes
        self.layout = layout
    }
}

public struct Pane: Identifiable, Sendable, Hashable {
    public let id: TmuxPaneID
    public var width: Int
    public var height: Int
    public var x: Int
    public var y: Int
    public var isActive: Bool
    /// True when this pane's window is zoomed (tmux `window_zoomed_flag`). The
    /// flag is per-window, so every pane in a zoomed window reports it; the
    /// zoomed pane itself is the active one.
    public var isZoomed: Bool
    public var currentCommand: String?
    public var title: String?

    public init(
        id: TmuxPaneID,
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        isActive: Bool,
        isZoomed: Bool = false,
        currentCommand: String?,
        title: String?
    ) {
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
