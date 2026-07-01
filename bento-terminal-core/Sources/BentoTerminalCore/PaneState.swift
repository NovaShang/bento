import Foundation
import os
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private let profileLog = Logger(subsystem: "com.bento.terminalcore", category: "profiles")

/// The three states a pane can be in
public enum PaneState: Equatable {
    case working                          // Command is running, producing output
    case idle                             // No recent output, shell prompt visible
    case awaitingInput(profile: String)   // Waiting for user input (y/N prompt, etc.)
}

public extension PaneState {
    /// Status-dot color as 0xRRGGBB — one source of truth for both platforms
    /// (working green / idle gray / awaiting amber). Matches the iOS STTheme dots.
    var dotColorHex: UInt32 {
        switch self {
        case .working:       return 0x30D158
        case .idle:          return 0x8E8E93
        case .awaitingInput: return 0xFF9F0A
        }
    }

    #if canImport(AppKit)
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat((dotColorHex >> 16) & 0xFF) / 255,
                green: CGFloat((dotColorHex >> 8) & 0xFF) / 255,
                blue: CGFloat(dotColorHex & 0xFF) / 255, alpha: 1)
    }
    #elseif canImport(UIKit)
    var uiColor: UIColor {
        UIColor(red: CGFloat((dotColorHex >> 16) & 0xFF) / 255,
                green: CGFloat((dotColorHex >> 8) & 0xFF) / 255,
                blue: CGFloat(dotColorHex & 0xFF) / 255, alpha: 1)
    }
    #endif

    /// Alpha for the translucent state wash overlaid on the whole pane (over the
    /// terminal surface), so a pane's state reads from across the room — not just
    /// from the title-bar dot. Idle = 0 (neutral, no wash) so only attention
    /// states stand out; awaiting gets the strongest tint. One source of truth
    /// for both platforms, mirroring `dotColorHex`.
    var tintAlpha: CGFloat {
        switch self {
        case .idle:          return 0
        case .working:       return 0.05
        case .awaitingInput: return 0.12
        }
    }

    #if canImport(AppKit)
    /// Translucent wash color for this state, or nil when it should show no tint.
    var tintNSColor: NSColor? {
        tintAlpha > 0 ? nsColor.withAlphaComponent(tintAlpha) : nil
    }
    #elseif canImport(UIKit)
    var tintUIColor: UIColor? {
        tintAlpha > 0 ? uiColor.withAlphaComponent(tintAlpha) : nil
    }
    #endif

    /// Accent color (0xRRGGBB) for pane *chrome* — the title-bar band and the
    /// border — when the state should stand out. nil for idle = neutral chrome.
    /// Working/awaiting reuse the dot's green/amber; "done, unseen" (blue) isn't
    /// a PaneState, so the view layers that color on itself. One source of truth
    /// for both platforms, alongside `dotColorHex` / `tintAlpha`.
    var chromeAccentHex: UInt32? {
        switch self {
        case .working:       return 0x30D158
        case .awaitingInput: return 0xFF9F0A
        case .idle:          return nil
        }
    }

    #if canImport(AppKit)
    var chromeAccentNSColor: NSColor? {
        chromeAccentHex.map {
            NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255,
                    green: CGFloat(($0 >> 8) & 0xFF) / 255,
                    blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
        }
    }
    #elseif canImport(UIKit)
    var chromeAccentUIColor: UIColor? {
        chromeAccentHex.map {
            UIColor(red: CGFloat(($0 >> 16) & 0xFF) / 255,
                    green: CGFloat(($0 >> 8) & 0xFF) / 255,
                    blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
        }
    }
    #endif
}

/// A profile that defines how to detect a specific tool's awaiting-input state
public struct StateProfile: Identifiable, Codable {
    public var id: String
    public var name: String
    /// Regex patterns to match against the last N lines of output
    public var outputPatterns: [String]
    /// Regex patterns to match against the pane title (pane_title). Checked
    /// BEFORE output patterns (PRD §3.4 priority: Title 匹配 → 输出正则). Empty
    /// for the built-ins by default — a wrong title pattern causes false
    /// "awaiting" states, and detection reliability is the priority — but
    /// user/custom profiles can populate it.
    public var titlePatterns: [String]
    /// Command name pattern (matched against pane_current_command)
    public var commandPattern: String?
    /// Quick keys to show when this profile matches
    public var quickKeys: [QuickKey]
    /// Whether this is a built-in profile (can't be deleted)
    public var isBuiltIn: Bool = false
    /// Rich region/priority/AND-OR-NOT detection rules (the precise engine).
    /// nil for simple profiles that rely on `outputPatterns` activity detection.
    /// For built-ins this is refreshed from the code preset on load (see
    /// ProfileStore.mergeMissingBuiltIns) — detection logic stays preset-driven,
    /// user edits to name/outputPatterns/quickKeys persist.
    public var agentRules: AgentRuleSet?
    /// Line regexes that mark a USER-TURN START in the scrollback (for the
    /// scroll-bookmark / history nav). e.g. Claude Code: a line starting `❯ `.
    public var promptBoundary: [String]

    public init(id: String, name: String, outputPatterns: [String],
                titlePatterns: [String] = [],
                commandPattern: String?, quickKeys: [QuickKey], isBuiltIn: Bool = false,
                agentRules: AgentRuleSet? = nil, promptBoundary: [String] = []) {
        self.id = id; self.name = name; self.outputPatterns = outputPatterns
        self.titlePatterns = titlePatterns
        self.commandPattern = commandPattern; self.quickKeys = quickKeys
        self.isBuiltIn = isBuiltIn
        self.agentRules = agentRules; self.promptBoundary = promptBoundary
    }

    // Lenient decoder — defaults all fields so adding new ones doesn't
    // invalidate stored profiles.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.outputPatterns = (try? c.decode([String].self, forKey: .outputPatterns)) ?? []
        self.titlePatterns = (try? c.decode([String].self, forKey: .titlePatterns)) ?? []
        self.commandPattern = try? c.decodeIfPresent(String.self, forKey: .commandPattern)
        self.quickKeys = (try? c.decode([QuickKey].self, forKey: .quickKeys)) ?? []
        self.isBuiltIn = (try? c.decode(Bool.self, forKey: .isBuiltIn)) ?? false
        self.agentRules = try? c.decodeIfPresent(AgentRuleSet.self, forKey: .agentRules)
        self.promptBoundary = (try? c.decode([String].self, forKey: .promptBoundary)) ?? []
    }
}

public struct QuickKey: Identifiable, Codable {
    public var id: String
    public var label: String
    public var keys: String   // The string to send via send-keys
    public var isEnter: Bool  // Whether to also send Enter after

    public init(id: String, label: String, keys: String, isEnter: Bool) {
        self.id = id; self.label = label; self.keys = keys; self.isEnter = isEnter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.label = (try? c.decode(String.self, forKey: .label)) ?? ""
        self.keys = (try? c.decode(String.self, forKey: .keys)) ?? ""
        self.isEnter = (try? c.decode(Bool.self, forKey: .isEnter)) ?? false
    }
}

/// Manages state profiles — built-in presets + user-customizable
@MainActor
public final class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()

    @Published public var profiles: [StateProfile] = []

    private let storageKey = "state_profiles"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            // First launch — seed with built-ins.
            profiles = Self.defaultProfiles
            save()
            return
        }
        do {
            profiles = try JSONDecoder().decode([StateProfile].self, from: data)
            mergeMissingBuiltIns()
        } catch {
            // Decode failed (corrupt or schema change the lenient init still
            // couldn't absorb). Preserve the raw bytes under a sibling key so
            // we can recover later, and seed with built-ins so the app keeps
            // working. Do NOT overwrite the original key, that would silently
            // delete the broken data.
            let stamp = Int(Date().timeIntervalSince1970)
            UserDefaults.standard.set(data, forKey: "\(storageKey)_broken_\(stamp)")
            profileLog.error("Failed to decode state_profiles: \(String(describing: error)). Backed up under state_profiles_broken_\(stamp)")
            profiles = Self.defaultProfiles
        }
    }

    /// Append any built-in profile whose id isn't already stored. Lets existing
    /// installs (which seeded an older built-in set into UserDefaults) pick up
    /// profiles added in later versions — e.g. Codex / Vim — without clobbering
    /// the user's own profiles or edits to existing built-ins.
    private func mergeMissingBuiltIns() {
        var changed = false
        let existing = Set(profiles.map(\.id))
        let missing = Self.defaultProfiles.filter { !existing.contains($0.id) }
        if !missing.isEmpty {
            profiles.append(contentsOf: missing)
            changed = true
        }
        // Refresh the PRESET-DRIVEN detection fields on existing built-ins so
        // installs that stored an older built-in (e.g. before the rich rules /
        // boundary existed) pick them up. These have no editor, so this can't
        // clobber a user edit; user-editable fields (name/outputPatterns/
        // titlePatterns/quickKeys) are left as stored.
        let presetByID = Dictionary(uniqueKeysWithValues: Self.defaultProfiles.map { ($0.id, $0) })
        for i in profiles.indices where profiles[i].isBuiltIn {
            guard let preset = presetByID[profiles[i].id] else { continue }
            // Adopt preset detection logic (idempotent: only writes when different).
            if !sameRules(profiles[i].agentRules, preset.agentRules) {
                profiles[i].agentRules = preset.agentRules
                changed = true
            }
            if profiles[i].promptBoundary != preset.promptBoundary {
                profiles[i].promptBoundary = preset.promptBoundary
                changed = true
            }
        }
        if changed { save() }
    }

    /// Cheap structural compare of two optional rule sets (encode + equate JSON).
    private func sameRules(_ a: AgentRuleSet?, _ b: AgentRuleSet?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            let enc = JSONEncoder()
            return (try? enc.encode(x)) == (try? enc.encode(y))
        default: return false
        }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    public func resetToDefaults() {
        profiles = Self.defaultProfiles
        save()
    }

    /// Turn-boundary regexes for the profile matching this pane's command (used by
    /// the scroll turn-navigation scan). Empty when nothing matches → nav no-ops.
    public func promptBoundary(forCommand command: String?) -> [String] {
        guard let command, !command.isEmpty else { return [] }
        for p in profiles where !p.promptBoundary.isEmpty {
            if let cp = p.commandPattern, !cp.isEmpty, command.contains(cp) { return p.promptBoundary }
            if let r = p.agentRules, r.commandPatterns.contains(where: { command.contains($0) }) {
                return p.promptBoundary
            }
        }
        return []
    }

    // MARK: - Built-in Presets

    // Command-specific profiles are listed before the catch-all `genericShell`;
    // detection also enforces this precedence independent of order (see
    // StateDetectionService.detectState), so a merged-in profile can't be
    // shadowed by the generic one.
    public static let defaultProfiles: [StateProfile] = [claudeCode, codex, gitInteractive, vim, genericShell]

    public static let claudeCode = StateProfile(
        id: "claude-code",
        name: "Claude Code",
        outputPatterns: [
            "Do you want to proceed\\?",
            "Allow .* to",
            "\\(y[/\\|]n\\)",
            "\\(Y[/\\|]n\\)",
            "Press Enter to",
            "Do you want to create",
            "Would you like",
            "Approve\\?",
            "approve this",
            "\\? \\(yes/no\\)",
            "Continue\\?",
            "Overwrite\\?",
        ],
        commandPattern: "claude",
        quickKeys: [
            QuickKey(id: "y", label: "Yes", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "No", keys: "n", isEnter: true),
            QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
            QuickKey(id: "esc", label: "Esc", keys: "\u{1b}", isEnter: false),
        ],
        isBuiltIn: true,
        // Precise region/priority engine (preset data; was hardcoded in
        // AgentStatusRules). Drives working/idle/blocked from a clean snapshot.
        agentRules: .claudeCode,
        // A user-turn starts at a line `❯ ` (U+276F + ASCII space + content).
        // The live empty prompt is `❯`+NBSP, so requiring an ASCII space excludes it.
        promptBoundary: ["^\\s*\\x{276F}\\x{20}"]
    )

    public static let genericShell = StateProfile(
        id: "shell",
        name: "Shell",
        outputPatterns: [
            "\\[y/N\\]",
            "\\[Y/n\\]",
            "Continue\\?",
            "\\(yes/no\\)",
            "Are you sure",
            "Proceed\\?",
            "Overwrite .* \\?",
            "\\(y/n\\)",
        ],
        commandPattern: nil,
        quickKeys: [
            QuickKey(id: "y", label: "Y", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "N", keys: "n", isEnter: true),
            QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
        ],
        isBuiltIn: true
    )

    public static let codex = StateProfile(
        id: "codex",
        name: "Codex",
        outputPatterns: [
            "Allow .* to",
            "Do you want to proceed\\?",
            "\\(y[/\\|]n\\)",
            "\\(Y[/\\|]n\\)",
            "Approve\\?",
            "Apply this (change|patch)\\?",
            "Run this command\\?",
            "Press Enter to",
            "Continue\\?",
        ],
        commandPattern: "codex",
        quickKeys: [
            QuickKey(id: "y", label: "Yes", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "No", keys: "n", isEnter: true),
            QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
            QuickKey(id: "esc", label: "Esc", keys: "\u{1b}", isEnter: false),
        ],
        isBuiltIn: true
    )

    // commandPattern "vim" matches vim / nvim / gvim (substring). Vim is always
    // interactive, so only the explicit blocking prompts (swap-file, more-prompt,
    // y/n confirms) count as awaiting — ordinary editing stays "working".
    public static let vim = StateProfile(
        id: "vim",
        name: "Vim",
        outputPatterns: [
            "Press ENTER or type command to continue",
            "E325: ATTENTION",
            "Swap file .* already exists",
            "\\[O\\]pen Read-Only",
            "\\(R\\)ecover",
            "Save changes\\?",
            "overwrite existing file",
            "\\(y/n\\)",
            "\\[Y\\]es, \\(N\\)o",
        ],
        commandPattern: "vim",
        quickKeys: [
            QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
            QuickKey(id: "y", label: "y", keys: "y", isEnter: false),
            QuickKey(id: "n", label: "n", keys: "n", isEnter: false),
            QuickKey(id: "esc", label: "Esc", keys: "\u{1b}", isEnter: false),
        ],
        isBuiltIn: true
    )

    public static let gitInteractive = StateProfile(
        id: "git",
        name: "Git Interactive",
        outputPatterns: [
            "Stage this hunk",
            "Discard this hunk",
            "Apply this hunk",
            "Stash this hunk",
        ],
        commandPattern: "git",
        quickKeys: [
            QuickKey(id: "y", label: "y", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "n", keys: "n", isEnter: true),
            QuickKey(id: "q", label: "q", keys: "q", isEnter: true),
            QuickKey(id: "a", label: "a", keys: "a", isEnter: true),
            QuickKey(id: "s", label: "s", keys: "s", isEnter: true),
        ],
        isBuiltIn: true
    )
}

/// Backward compatibility
@MainActor
public enum BuiltInProfiles {
    public static var all: [StateProfile] { ProfileStore.shared.profiles }
}
