import Foundation

/// Type-safe builder for tmux commands sent over control mode (`tmux -CC`).
/// Convert to a wire string via `commandString`; the control-mode service
/// appends the trailing newline.
public enum TmuxCommand: Sendable {
    // Session
    case newSession(name: String? = nil, groupWith: String? = nil)
    case attachSession(name: String)
    case listSessions

    // Window
    case newWindow(target: String? = nil, name: String? = nil)
    case listWindows(target: String? = nil)
    case selectWindow(id: TmuxWindowID)
    case renameWindow(id: TmuxWindowID, name: String)
    /// Rename the client's currently-attached session (no `-t` → current).
    case renameSession(name: String)

    // Pane
    case splitWindow(target: TmuxPaneID? = nil, horizontal: Bool)
    case selectPane(id: TmuxPaneID)
    /// Set a pane's title (`pane_title`), what the UI shows in the pane title bar
    /// and List rows. Note: a foreground TUI can overwrite this via OSC.
    case setPaneTitle(id: TmuxPaneID, title: String)
    case listPanes(target: String? = nil, allWindows: Bool = false)
    case killPane(id: TmuxPaneID)
    /// Swap a pane with the previous/next pane in the window (`swap-pane -U/-D`).
    case swapPaneUp(id: TmuxPaneID)
    case swapPaneDown(id: TmuxPaneID)
    /// Swap two specific panes (`swap-pane -s ... -t ...`); used by drag-to-swap.
    case swapPanes(source: TmuxPaneID, destination: TmuxPaneID)
    case killSession(name: String? = nil)
    /// Capture a pane's text. `lines == nil` captures only the live visible
    /// screen (no scrollback) — what status detection wants, since stale prompt
    /// text in scrollback must not trigger a false "blocked". A positive `lines`
    /// captures that many lines up from the bottom (incl. scrollback). `escapes`
    /// keeps SGR color codes (off by default → clean text for matching).
    case capturePane(id: TmuxPaneID, lines: Int? = 10, escapes: Bool = false)
    case resizePane(id: TmuxPaneID, width: Int, height: Int)
    case zoomPane(id: TmuxPaneID)
    /// Resize pane by N cells. `direction` is one of `"L"`, `"R"`, `"U"`, `"D"`.
    case resizePaneBy(id: TmuxPaneID, direction: String, amount: Int)

    // Input
    case sendKeys(pane: TmuxPaneID, keys: String, literal: Bool = true)

    // Info
    case displayMessage(format: String, target: TmuxPaneID? = nil)
    case listClients

    // Layout
    case selectLayout(window: TmuxWindowID, layout: String)

    // Client
    case refreshClient(width: Int, height: Int)
    /// Switch the attached control client to another session on the same server
    /// (tmux emits %session-changed, which re-syncs windows/panes).
    case switchClient(session: String)

    /// Build the tmux command string (without trailing newline).
    public var commandString: String {
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

        case .renameSession(let name):
            return "rename-session \(escapeArg(name))"

        case .splitWindow(let target, let horizontal):
            var cmd = "split-window"
            cmd += horizontal ? " -h" : " -v"
            if let target { cmd += " -t \(target)" }
            // Inherit the source pane's working directory. tmux expands the
            // format against the target pane server-side, so we don't have to
            // query the cwd ourselves.
            cmd += " -c '#{pane_current_path}'"
            return cmd

        case .selectPane(let id):
            return "select-pane -t \(id)"

        case .setPaneTitle(let id, let title):
            return "select-pane -t \(id) -T \(escapeArg(title))"

        case .listPanes(let target, let allWindows):
            var cmd = "list-panes -F '#{pane_id}:#{pane_width}:#{pane_height}:#{pane_left}:#{pane_top}:#{pane_active}:#{window_zoomed_flag}:#{pane_current_command}:#{mouse_any_flag}:#{mouse_sgr_flag}:#{pane_title}'"
            if allWindows { cmd += " -a" }
            else if let target { cmd += " -t \(escapeArg(target))" }
            return cmd

        case .killPane(let id):
            return "kill-pane -t \(id)"

        case .swapPaneUp(let id):
            return "swap-pane -U -t \(id)"

        case .swapPaneDown(let id):
            return "swap-pane -D -t \(id)"

        case .swapPanes(let source, let destination):
            return "swap-pane -s \(source) -t \(destination)"

        case .killSession(let name):
            if let name { return "kill-session -t \(escapeArg(name))" }
            return "kill-session"

        case .capturePane(let id, let lines, let escapes):
            // -p: print to stdout, -J: join wrapped lines, -e: SGR colors,
            // -S: start line (negative = from bottom). No -S → visible screen only.
            var cmd = "capture-pane -t \(id) -p -J"
            if escapes { cmd += " -e" }
            if let lines { cmd += " -S -\(lines)" }
            return cmd

        case .resizePane(let id, let width, let height):
            return "resize-pane -t \(id) -x \(width) -y \(height)"

        case .zoomPane(let id):
            return "resize-pane -Z -t \(id)"

        case .resizePaneBy(let id, let direction, let amount):
            return "resize-pane -t \(id) -\(direction) \(amount)"

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

        case .switchClient(let session):
            return "switch-client -t \(escapeArg(session))"
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
