import Foundation

// MARK: - tmux ID Types

/// tmux session ID, e.g. "$0"
struct TmuxSessionID: Hashable, Codable, CustomStringConvertible {
    let raw: Int
    var description: String { "$\(raw)" }

    init(_ raw: Int) { self.raw = raw }

    init?(string: String) {
        guard string.hasPrefix("$"), let num = Int(string.dropFirst()) else { return nil }
        self.raw = num
    }
}

/// tmux window ID, e.g. "@5"
struct TmuxWindowID: Hashable, Codable, CustomStringConvertible {
    let raw: Int
    var description: String { "@\(raw)" }

    init(_ raw: Int) { self.raw = raw }

    init?(string: String) {
        guard string.hasPrefix("@"), let num = Int(string.dropFirst()) else { return nil }
        self.raw = num
    }
}

/// tmux pane ID, e.g. "%3"
struct TmuxPaneID: Hashable, Codable, CustomStringConvertible {
    let raw: Int
    var description: String { "%\(raw)" }

    init(_ raw: Int) { self.raw = raw }

    init?(string: String) {
        guard string.hasPrefix("%"), let num = Int(string.dropFirst()) else { return nil }
        self.raw = num
    }
}

// MARK: - Notifications

/// Parsed tmux control mode notifications
enum TmuxNotification {
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

/// A command response block from tmux
struct TmuxCommandResponse {
    let commandNumber: Int
    let isError: Bool
    let output: String
}

// MARK: - Layout Parsing

/// Parsed pane layout from tmux layout string
struct TmuxPaneLayout {
    let paneID: TmuxPaneID
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

// MARK: - Models

struct Workspace: Identifiable {
    let id: TmuxSessionID
    var name: String
    var windows: [TmuxWindow]
}

struct TmuxWindow: Identifiable {
    let id: TmuxWindowID
    var name: String
    var panes: [Pane]
    var layout: String?
}

struct Pane: Identifiable {
    let id: TmuxPaneID
    var width: Int
    var height: Int
    var x: Int
    var y: Int
    var isActive: Bool
    var currentCommand: String?
    var title: String?
}
