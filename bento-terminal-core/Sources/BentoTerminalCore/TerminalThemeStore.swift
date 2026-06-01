import Foundation

/// A terminal color scheme — background, foreground, cursor, and the 16 ANSI
/// colors, as 24-bit `0xRRGGBB`. Shared by iOS + macOS (one source of truth).
/// Platform UIColor/NSColor helpers live in the app targets.
public struct TerminalColorTheme: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let bg: UInt32
    public let fg: UInt32
    public let cursor: UInt32
    /// 16 ANSI colors: indices 0-7 normal, 8-15 bright.
    public let ansi: [UInt32]

    public init(id: String, name: String, isDark: Bool, bg: UInt32, fg: UInt32, cursor: UInt32, ansi: [UInt32]) {
        self.id = id; self.name = name; self.isDark = isDark
        self.bg = bg; self.fg = fg; self.cursor = cursor; self.ansi = ansi
    }

    // Lenient decoder — defaults every field so a saved custom theme survives
    // future schema additions.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        self.isDark = (try? c.decode(Bool.self, forKey: .isDark)) ?? true
        self.bg = (try? c.decode(UInt32.self, forKey: .bg)) ?? 0x000000
        self.fg = (try? c.decode(UInt32.self, forKey: .fg)) ?? 0xFFFFFF
        self.cursor = (try? c.decode(UInt32.self, forKey: .cursor)) ?? 0xFFFFFF
        self.ansi = (try? c.decode([UInt32].self, forKey: .ansi)) ?? TerminalColorTheme.defaultAnsi
    }
}

public extension TerminalColorTheme {
    /// Sentinel ID for the system-adaptive theme.
    static let systemID = "system"

    static let builtIn: [TerminalColorTheme] = [
        TerminalColorTheme(id: systemID, name: "System", isDark: true,
                           bg: 0x0F1115, fg: 0xE6E8EE, cursor: 0xE6E8EE, ansi: defaultAnsi),
        TerminalColorTheme(id: "dracula", name: "Dracula", isDark: true,
                           bg: 0x282A36, fg: 0xF8F8F2, cursor: 0xF8F8F2, ansi: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]),
        TerminalColorTheme(id: "solarized-dark", name: "Solarized Dark", isDark: true,
                           bg: 0x002B36, fg: 0x839496, cursor: 0x93A1A1, ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]),
        TerminalColorTheme(id: "solarized-light", name: "Solarized Light", isDark: false,
                           bg: 0xFDF6E3, fg: 0x657B83, cursor: 0x586E75, ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]),
        TerminalColorTheme(id: "tokyo-night", name: "Tokyo Night", isDark: true,
                           bg: 0x1A1B26, fg: 0xC0CAF5, cursor: 0xC0CAF5, ansi: [
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5]),
        TerminalColorTheme(id: "nord", name: "Nord", isDark: true,
                           bg: 0x2E3440, fg: 0xD8DEE9, cursor: 0xD8DEE9, ansi: [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]),
        TerminalColorTheme(id: "gruvbox-dark", name: "Gruvbox Dark", isDark: true,
                           bg: 0x282828, fg: 0xEBDBB2, cursor: 0xEBDBB2, ansi: [
            0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]),
        TerminalColorTheme(id: "monokai", name: "Monokai", isDark: true,
                           bg: 0x272822, fg: 0xF8F8F2, cursor: 0xF8F8F2, ansi: [
            0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
            0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5]),
    ]

    static let defaultAnsi: [UInt32] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]

    static func find(id: String) -> TerminalColorTheme {
        if let m = builtIn.first(where: { $0.id == id }) { return m }
        if let m = ThemeStore.loadCustomThemes().first(where: { $0.id == id }) { return m }
        return builtIn[0]
    }

    /// Parse an iTerm2 `.itermcolors` plist into a theme.
    static func fromITermColors(data: Data, name: String) throws -> TerminalColorTheme {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: [String: Any]] else {
            throw NSError(domain: "iTerm2Theme", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a valid .itermcolors file"])
        }
        func hex(_ key: String, _ fallback: UInt32) -> UInt32 {
            guard let e = dict[key] else { return fallback }
            let r = UInt32(max(0, min(1, (e["Red Component"] as? Double) ?? 0)) * 255)
            let g = UInt32(max(0, min(1, (e["Green Component"] as? Double) ?? 0)) * 255)
            let b = UInt32(max(0, min(1, (e["Blue Component"] as? Double) ?? 0)) * 255)
            return (r << 16) | (g << 8) | b
        }
        let bg = hex("Background Color", 0x000000)
        let fg = hex("Foreground Color", 0xCCCCCC)
        let cursor = hex("Cursor Color", fg)
        let ansi = (0..<16).map { hex("Ansi \($0) Color", 0) }
        let r = Double((bg >> 16) & 0xFF), g = Double((bg >> 8) & 0xFF), b = Double(bg & 0xFF)
        let isDark = (0.2126 * r + 0.7152 * g + 0.0722 * b) < 128
        return TerminalColorTheme(id: "imported-" + UUID().uuidString.prefix(8).lowercased(),
                                  name: name, isDark: isDark, bg: bg, fg: fg, cursor: cursor, ansi: ansi)
    }
}

/// Persists the user's terminal theme + font choice and notifies observers.
/// Shared by iOS + macOS so the two clients use one schema and the same
/// UserDefaults keys (a later iCloud KVS layer can wrap these).
@MainActor
public final class ThemeStore: ObservableObject {
    public static let shared = ThemeStore()
    nonisolated private static let customKey = "terminal_custom_themes_v1"

    @Published public var current: TerminalColorTheme {
        didSet {
            UserDefaults.standard.set(current.id, forKey: "terminal_theme_id")
            NotificationCenter.default.post(name: .terminalThemeChanged, object: nil)
        }
    }

    @Published public var customThemes: [TerminalColorTheme] {
        didSet { saveCustomThemes() }
    }

    public var allThemes: [TerminalColorTheme] { TerminalColorTheme.builtIn + customThemes }

    // MARK: Font prefs (same UserDefaults keys both platforms use)

    /// Terminal font size in points. Default 13.
    public var fontSize: Double {
        let v = UserDefaults.standard.double(forKey: "terminal_font_size")
        return v > 0 ? v : 13
    }

    /// Selected font-family token (e.g. "jetbrains"); nil = engine default.
    public var fontFamilyToken: String? {
        UserDefaults.standard.string(forKey: "terminal_font_family")
    }

    /// ghostty font-family name for the selected token, or nil for the default.
    public var ghosttyFontFamily: String? {
        switch fontFamilyToken {
        case "menlo":        return "Menlo"
        case "courier":      return "Courier New"
        case "jetbrains":    return "JetBrains Mono"
        case "maple-nf-cn":  return "Maple Mono NF CN"
        case "sf-mono", "system", "system-medium", nil, "": return nil
        default:             return fontFamilyToken
        }
    }

    /// Build the engine-agnostic TerminalTheme (colors + font) for a surface.
    public func makeTerminalTheme() -> TerminalTheme {
        TerminalTheme(background: current.bg, foreground: current.fg,
                      ansi: current.ansi, fontSize: fontSize, fontFamily: ghosttyFontFamily)
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: "terminal_theme_id") ?? TerminalColorTheme.systemID
        self.customThemes = ThemeStore.loadCustomThemes()
        self.current = TerminalColorTheme.find(id: stored)
    }

    nonisolated public static func loadCustomThemes() -> [TerminalColorTheme] {
        guard let data = UserDefaults.standard.data(forKey: customKey) else { return [] }
        do {
            return try JSONDecoder().decode([TerminalColorTheme].self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            UserDefaults.standard.set(data, forKey: "\(customKey)_broken_\(stamp)")
            dlog("Failed to decode custom themes: \(error)")
            return []
        }
    }

    private func saveCustomThemes() {
        guard let data = try? JSONEncoder().encode(customThemes) else { return }
        UserDefaults.standard.set(data, forKey: Self.customKey)
    }

    public func addCustomTheme(_ theme: TerminalColorTheme) {
        customThemes.append(theme)
        current = theme
    }

    public func removeCustomTheme(_ id: String) {
        customThemes.removeAll { $0.id == id }
        if current.id == id { current = TerminalColorTheme.builtIn[0] }
    }

    /// Set the current theme by id (built-in or custom).
    public func select(id: String) {
        current = TerminalColorTheme.find(id: id)
    }
}

public extension Notification.Name {
    static let terminalThemeChanged = Notification.Name("terminalThemeChanged")
    static let terminalFontChanged = Notification.Name("terminalFontChanged")
}
