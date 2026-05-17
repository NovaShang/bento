import Foundation
import UIKit

/// A terminal color scheme — background, foreground, and the 16 ANSI colors.
/// Stored as 24-bit RGB hex values; converted to UIColor / SwiftTerm.Color
/// when applied to the TerminalView.
struct TerminalColorTheme: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let isDark: Bool
    let bg: UInt32
    let fg: UInt32
    let cursor: UInt32
    /// 16 ANSI colors: indices 0-7 normal, 8-15 bright.
    let ansi: [UInt32]

    var bgColor: UIColor { UIColor(hex: bg) }
    var fgColor: UIColor { UIColor(hex: fg) }
    var cursorColor: UIColor { UIColor(hex: cursor) }
}

extension TerminalColorTheme {
    /// Sentinel ID for the system-adaptive theme. Resolved at apply time
    /// rather than stored, so it follows light/dark mode changes.
    static let systemID = "system"

    /// All built-in themes. The "system" entry is rendered dynamically by
    /// reading STTheme; the rest are static.
    static let builtIn: [TerminalColorTheme] = [
        // The system entry is a placeholder. Its colors are not used directly;
        // applyTheme() short-circuits and reads STTheme instead.
        TerminalColorTheme(
            id: systemID,
            name: "System",
            isDark: true,
            bg: 0x0F1115,
            fg: 0xE6E8EE,
            cursor: 0xE6E8EE,
            ansi: defaultAnsi
        ),
        TerminalColorTheme(
            id: "dracula",
            name: "Dracula",
            isDark: true,
            bg: 0x282A36,
            fg: 0xF8F8F2,
            cursor: 0xF8F8F2,
            ansi: [
                0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
                0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
                0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
            ]
        ),
        TerminalColorTheme(
            id: "solarized-dark",
            name: "Solarized Dark",
            isDark: true,
            bg: 0x002B36,
            fg: 0x839496,
            cursor: 0x93A1A1,
            ansi: [
                0x073642, 0xDC322F, 0x859900, 0xB58900,
                0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
                0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
            ]
        ),
        TerminalColorTheme(
            id: "solarized-light",
            name: "Solarized Light",
            isDark: false,
            bg: 0xFDF6E3,
            fg: 0x657B83,
            cursor: 0x586E75,
            ansi: [
                0x073642, 0xDC322F, 0x859900, 0xB58900,
                0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
                0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
            ]
        ),
        TerminalColorTheme(
            id: "tokyo-night",
            name: "Tokyo Night",
            isDark: true,
            bg: 0x1A1B26,
            fg: 0xC0CAF5,
            cursor: 0xC0CAF5,
            ansi: [
                0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68,
                0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68,
                0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
            ]
        ),
        TerminalColorTheme(
            id: "nord",
            name: "Nord",
            isDark: true,
            bg: 0x2E3440,
            fg: 0xD8DEE9,
            cursor: 0xD8DEE9,
            ansi: [
                0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
            ]
        ),
        TerminalColorTheme(
            id: "gruvbox-dark",
            name: "Gruvbox Dark",
            isDark: true,
            bg: 0x282828,
            fg: 0xEBDBB2,
            cursor: 0xEBDBB2,
            ansi: [
                0x282828, 0xCC241D, 0x98971A, 0xD79921,
                0x458588, 0xB16286, 0x689D6A, 0xA89984,
                0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F,
                0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
            ]
        ),
        TerminalColorTheme(
            id: "monokai",
            name: "Monokai",
            isDark: true,
            bg: 0x272822,
            fg: 0xF8F8F2,
            cursor: 0xF8F8F2,
            ansi: [
                0x272822, 0xF92672, 0xA6E22E, 0xF4BF75,
                0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
                0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75,
                0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5,
            ]
        ),
    ]

    private static let defaultAnsi: [UInt32] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00,
        0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00,
        0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]

    static func find(id: String) -> TerminalColorTheme {
        if let m = builtIn.first(where: { $0.id == id }) { return m }
        if let m = ThemeStore.loadCustomThemes().first(where: { $0.id == id }) { return m }
        return builtIn[0]
    }

    /// Parse an iTerm2 .itermcolors plist into a TerminalColorTheme.
    /// `name` defaults to the file basename (caller can override).
    static func fromITermColors(data: Data, name: String) throws -> TerminalColorTheme {
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        guard let dict = plist as? [String: [String: Any]] else {
            throw NSError(domain: "iTerm2Theme", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Not a valid .itermcolors file"
            ])
        }

        func hex(forKey key: String, fallback: UInt32) -> UInt32 {
            guard let entry = dict[key] else { return fallback }
            let r = (entry["Red Component"] as? Double) ?? 0
            let g = (entry["Green Component"] as? Double) ?? 0
            let b = (entry["Blue Component"] as? Double) ?? 0
            let R = UInt32((max(0, min(1, r))) * 255)
            let G = UInt32((max(0, min(1, g))) * 255)
            let B = UInt32((max(0, min(1, b))) * 255)
            return (R << 16) | (G << 8) | B
        }

        let bg = hex(forKey: "Background Color", fallback: 0x000000)
        let fg = hex(forKey: "Foreground Color", fallback: 0xCCCCCC)
        let cursor = hex(forKey: "Cursor Color", fallback: fg)
        var ansi: [UInt32] = []
        for i in 0..<16 {
            ansi.append(hex(forKey: "Ansi \(i) Color", fallback: 0))
        }

        // Crude dark/light heuristic from background luma.
        let R = Double((bg >> 16) & 0xFF)
        let G = Double((bg >> 8) & 0xFF)
        let B = Double(bg & 0xFF)
        let luma = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let isDark = luma < 128

        return TerminalColorTheme(
            id: "imported-" + UUID().uuidString.prefix(8),
            name: name,
            isDark: isDark,
            bg: bg,
            fg: fg,
            cursor: cursor,
            ansi: ansi
        )
    }
}

/// Persists the user's theme choice and notifies observers when it changes.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    nonisolated private static let customKey = "terminal_custom_themes_v1"

    @Published var current: TerminalColorTheme {
        didSet {
            UserDefaults.standard.set(current.id, forKey: "terminal_theme_id")
            NotificationCenter.default.post(name: .terminalThemeChanged, object: nil)
        }
    }

    @Published var customThemes: [TerminalColorTheme] {
        didSet { saveCustomThemes() }
    }

    var allThemes: [TerminalColorTheme] {
        TerminalColorTheme.builtIn + customThemes
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: "terminal_theme_id") ?? TerminalColorTheme.systemID
        self.customThemes = ThemeStore.loadCustomThemes()
        self.current = TerminalColorTheme.find(id: stored)
    }

    nonisolated static func loadCustomThemes() -> [TerminalColorTheme] {
        guard let data = UserDefaults.standard.data(forKey: customKey),
              let arr = try? JSONDecoder().decode([TerminalColorTheme].self, from: data)
        else { return [] }
        return arr
    }

    private func saveCustomThemes() {
        guard let data = try? JSONEncoder().encode(customThemes) else { return }
        UserDefaults.standard.set(data, forKey: Self.customKey)
    }

    func addCustomTheme(_ theme: TerminalColorTheme) {
        customThemes.append(theme)
        current = theme
    }

    func removeCustomTheme(_ id: String) {
        customThemes.removeAll { $0.id == id }
        if current.id == id {
            current = TerminalColorTheme.builtIn[0]
        }
    }
}

extension Notification.Name {
    static let terminalThemeChanged = Notification.Name("terminalThemeChanged")
    static let terminalFontChanged = Notification.Name("terminalFontChanged")
}
