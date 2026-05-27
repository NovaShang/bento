import Foundation

/// The three states a pane can be in
enum PaneState: Equatable {
    case working                          // Command is running, producing output
    case idle                             // No recent output, shell prompt visible
    case awaitingInput(profile: String)   // Waiting for user input (y/N prompt, etc.)
}

/// A profile that defines how to detect a specific tool's awaiting-input state
struct StateProfile: Identifiable, Codable {
    var id: String
    var name: String
    /// Regex patterns to match against the last N lines of output
    var outputPatterns: [String]
    /// Command name pattern (matched against pane_current_command)
    var commandPattern: String?
    /// Quick keys to show when this profile matches
    var quickKeys: [QuickKey]
    /// Whether this is a built-in profile (can't be deleted)
    var isBuiltIn: Bool = false

    init(id: String, name: String, outputPatterns: [String],
         commandPattern: String?, quickKeys: [QuickKey], isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.outputPatterns = outputPatterns
        self.commandPattern = commandPattern; self.quickKeys = quickKeys
        self.isBuiltIn = isBuiltIn
    }

    // Lenient decoder — defaults all fields so adding new ones doesn't
    // invalidate stored profiles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.outputPatterns = (try? c.decode([String].self, forKey: .outputPatterns)) ?? []
        self.commandPattern = try? c.decodeIfPresent(String.self, forKey: .commandPattern)
        self.quickKeys = (try? c.decode([QuickKey].self, forKey: .quickKeys)) ?? []
        self.isBuiltIn = (try? c.decode(Bool.self, forKey: .isBuiltIn)) ?? false
    }
}

struct QuickKey: Identifiable, Codable {
    var id: String
    var label: String
    var keys: String   // The string to send via send-keys
    var isEnter: Bool  // Whether to also send Enter after

    init(id: String, label: String, keys: String, isEnter: Bool) {
        self.id = id; self.label = label; self.keys = keys; self.isEnter = isEnter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.label = (try? c.decode(String.self, forKey: .label)) ?? ""
        self.keys = (try? c.decode(String.self, forKey: .keys)) ?? ""
        self.isEnter = (try? c.decode(Bool.self, forKey: .isEnter)) ?? false
    }
}

/// Manages state profiles — built-in presets + user-customizable
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var profiles: [StateProfile] = []

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
        } catch {
            // Decode failed (corrupt or schema change the lenient init still
            // couldn't absorb). Preserve the raw bytes under a sibling key so
            // we can recover later, and seed with built-ins so the app keeps
            // working. Do NOT overwrite the original key, that would silently
            // delete the broken data.
            let stamp = Int(Date().timeIntervalSince1970)
            UserDefaults.standard.set(data, forKey: "\(storageKey)_broken_\(stamp)")
            dlog("Failed to decode state_profiles: \(error). Backed up under state_profiles_broken_\(stamp)")
            profiles = Self.defaultProfiles
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func resetToDefaults() {
        profiles = Self.defaultProfiles
        save()
    }

    // MARK: - Built-in Presets

    static let defaultProfiles: [StateProfile] = [claudeCode, genericShell, gitInteractive]

    static let claudeCode = StateProfile(
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
        isBuiltIn: true
    )

    static let genericShell = StateProfile(
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

    static let gitInteractive = StateProfile(
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
enum BuiltInProfiles {
    static var all: [StateProfile] { ProfileStore.shared.profiles }
}
