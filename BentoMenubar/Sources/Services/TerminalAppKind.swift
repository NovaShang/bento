import AppKit

/// TerminalAppKind enumerates the macOS terminals we can spawn a tmux
/// session into. Each one is opened via AppleScript (the only API that
/// reliably lets you both `create window` and `do script <cmd>` in one
/// hop) — except where the terminal's own `--args` / `-e` flags do the
/// same thing more cleanly.
///
/// iTerm2 deserves special treatment: when you hand it `tmux -CC ...`
/// it switches the attached session into its native multi-window
/// integration, where each tmux window is a real iTerm tab and each
/// pane is a real iTerm split. That's the experience the user is after.
enum TerminalAppKind: String, CaseIterable, Identifiable, Codable {
    case terminal = "Terminal"
    case iTerm    = "iTerm"
    case ghostty  = "Ghostty"
    case warp     = "Warp"

    var id: String { rawValue }

    /// Bundle identifier used both for "is this installed?" checks and
    /// for the AppleScript `tell application id "…"` form.
    var bundleID: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iTerm:    return "com.googlecode.iterm2"
        case .ghostty:  return "com.mitchellh.ghostty"
        case .warp:     return "dev.warp.Warp-Stable"
        }
    }

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm:    return "iTerm2"
        case .ghostty:  return "Ghostty"
        case .warp:     return "Warp"
        }
    }

    /// True if the app is installed on this Mac (any registered copy).
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Whether this terminal natively understands tmux control mode
    /// (`tmux -CC`) and renders panes as first-class windows/tabs.
    /// Currently only iTerm2 fully integrates.
    var supportsTmuxControlMode: Bool {
        switch self {
        case .iTerm:   return true
        default:       return false
        }
    }

    /// All terminals known to the app, in user-facing menu order.
    static var allInstalled: [TerminalAppKind] {
        Self.allCases.filter(\.isInstalled)
    }

    /// User's currently-preferred terminal, falling back gracefully if
    /// the saved choice is no longer installed. Persists via
    /// UserDefaults under `preferredTerminal`.
    static var preferred: TerminalAppKind {
        get {
            let raw = UserDefaults.standard.string(forKey: "preferredTerminal") ?? ""
            if let kind = TerminalAppKind(rawValue: raw), kind.isInstalled {
                return kind
            }
            // Auto-pick the best available: iTerm2 > Ghostty > Warp > Terminal.
            for cand in [TerminalAppKind.iTerm, .ghostty, .warp, .terminal] where cand.isInstalled {
                return cand
            }
            // Terminal.app is shipped with macOS, so this fallback is
            // theoretical — included for completeness.
            return .terminal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preferredTerminal")
        }
    }
}
