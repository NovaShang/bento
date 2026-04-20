import Foundation

/// Type-safe builder for tmux commands sent via control mode
enum TmuxCommand {
    // Session
    case newSession(name: String? = nil, groupWith: String? = nil)
    case attachSession(name: String)
    case listSessions

    // Window
    case newWindow(target: String? = nil, name: String? = nil)
    case listWindows(target: String? = nil)
    case selectWindow(id: TmuxWindowID)
    case renameWindow(id: TmuxWindowID, name: String)

    // Pane
    case splitWindow(target: TmuxPaneID? = nil, horizontal: Bool)
    case selectPane(id: TmuxPaneID)
    case listPanes(target: String? = nil, allWindows: Bool = false)
    case killPane(id: TmuxPaneID)
    case resizePane(id: TmuxPaneID, width: Int, height: Int)

    // Input
    case sendKeys(pane: TmuxPaneID, keys: String, literal: Bool = true)

    // Info
    case displayMessage(format: String, target: TmuxPaneID? = nil)
    case listClients

    // Layout
    case selectLayout(window: TmuxWindowID, layout: String)

    // Client
    case refreshClient(width: Int, height: Int)

    /// Build the tmux command string (without trailing newline)
    var commandString: String {
        switch self {
        case .newSession(let name, let groupWith):
            var cmd = "new-session -d"
            if let group = groupWith {
                cmd += " -t \(group)"
            }
            if let name {
                cmd += " -s \(escapeArg(name))"
            }
            return cmd

        case .attachSession(let name):
            return "attach-session -t \(escapeArg(name))"

        case .listSessions:
            return "list-sessions -F '#{session_id}:#{session_name}'"

        case .newWindow(let target, let name):
            var cmd = "new-window"
            if let target { cmd += " -t \(escapeArg(target))" }
            if let name { cmd += " -n \(escapeArg(name))" }
            return cmd

        case .listWindows(let target):
            var cmd = "list-windows -F '#{window_id}:#{window_name}:#{window_layout}:#{window_active}'"
            if let target { cmd += " -t \(escapeArg(target))" }
            return cmd

        case .selectWindow(let id):
            return "select-window -t \(id)"

        case .renameWindow(let id, let name):
            return "rename-window -t \(id) \(escapeArg(name))"

        case .splitWindow(let target, let horizontal):
            var cmd = "split-window"
            cmd += horizontal ? " -h" : " -v"
            if let target { cmd += " -t \(target)" }
            return cmd

        case .selectPane(let id):
            return "select-pane -t \(id)"

        case .listPanes(let target, let allWindows):
            var cmd = "list-panes -F '#{pane_id}:#{pane_width}:#{pane_height}:#{pane_left}:#{pane_top}:#{pane_active}:#{pane_current_command}:#{pane_title}'"
            if allWindows { cmd += " -a" }
            else if let target { cmd += " -t \(escapeArg(target))" }
            return cmd

        case .killPane(let id):
            return "kill-pane -t \(id)"

        case .resizePane(let id, let width, let height):
            return "resize-pane -t \(id) -x \(width) -y \(height)"

        case .sendKeys(let pane, let keys, let literal):
            var cmd = "send-keys -t \(pane)"
            if literal { cmd += " -l" }
            cmd += " \(escapeArg(keys))"
            return cmd

        case .displayMessage(let format, let target):
            var cmd = "display-message -p"
            if let target { cmd += " -t \(target)" }
            cmd += " \(escapeArg(format))"
            return cmd

        case .listClients:
            return "list-clients -F '#{client_name}:#{client_session}'"

        case .selectLayout(let window, let layout):
            return "select-layout -t \(window) \(escapeArg(layout))"

        case .refreshClient(let width, let height):
            return "refresh-client -C \(width),\(height)"
        }
    }

    private func escapeArg(_ arg: String) -> String {
        if arg.contains(" ") || arg.contains("'") || arg.contains("\"") || arg.contains("\\") {
            let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return arg
    }
}
