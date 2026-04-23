import UIKit
import SwiftUI

// MARK: - Design Tokens

/// Centralized design tokens matching the SpeakTerm design prototype.
/// iOS system color palette + terminal dark/light themes.
enum STTheme {

    // MARK: - Terminal Palettes

    /// Dark terminal theme — default dev-tool palette
    enum TermDark {
        static let bg          = UIColor(hex: 0x0F1115)
        static let bgIdle      = UIColor(hex: 0x0B0D11)
        static let bgAwait     = UIColor(hex: 0x2A1F10)
        static let bgWorking   = UIColor(hex: 0x0C3320)
        static let fg          = UIColor(hex: 0xE6E8EE)
        static let dim         = UIColor(hex: 0x8B8F9B)
        static let muted       = UIColor(hex: 0x55596A)
        static let border      = UIColor.white.withAlphaComponent(0.06)
        static let borderActive = UIColor(hex: 0x0A84FF)
        static let borderAwait = UIColor(hex: 0xFF9F0A)
        static let borderWork  = UIColor(hex: 0x30D158).withAlphaComponent(0.28)
        static let awaitInk    = UIColor(hex: 0xF0A959)
        static let workInk     = UIColor(hex: 0x9AE6B4)
    }

    /// Light terminal theme — warm paper, subtle state tints
    enum TermLight {
        static let bg          = UIColor.white
        static let bgIdle      = UIColor(hex: 0xF4F4F7)
        static let bgAwait     = UIColor(hex: 0xFFF5E0)
        static let bgWorking   = UIColor(hex: 0xE8F6EC)
        static let fg          = UIColor(hex: 0x1C1C1E)
        static let dim         = UIColor(hex: 0x6B6B70)
        static let muted       = UIColor(hex: 0xAEAEB2)
        static let border      = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.12)
        static let borderActive = UIColor(hex: 0x007AFF)
        static let borderAwait = UIColor(hex: 0xFF9500)
        static let borderWork  = UIColor(hex: 0x34C759).withAlphaComponent(0.28)
        static let awaitInk    = UIColor(hex: 0xB45309)
        static let workInk     = UIColor(hex: 0x1F7A3A)
    }

    // MARK: - Chrome Palettes (iOS System Colors)

    enum ChromeDark {
        static let app        = UIColor.black
        static let surface    = UIColor(hex: 0x1C1C1E)
        static let surface2   = UIColor(hex: 0x2C2C2E)
        static let grouped    = UIColor.black
        static let groupedSec = UIColor(hex: 0x1C1C1E)
        static let line       = UIColor(red: 84/255, green: 84/255, blue: 88/255, alpha: 0.65)
        static let lineO      = UIColor(red: 84/255, green: 84/255, blue: 88/255, alpha: 0.35)
        static let ink        = UIColor.white
        static let inkDim     = UIColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.6)
        static let inkMute    = UIColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.3)
        static let accent     = UIColor(hex: 0x0A84FF)
        static let amber      = UIColor(hex: 0xFF9F0A)
        static let green      = UIColor(hex: 0x30D158)
        static let red        = UIColor(hex: 0xFF453A)
    }

    enum ChromeLight {
        static let app        = UIColor(hex: 0xF2F2F7)
        static let surface    = UIColor.white
        static let surface2   = UIColor(hex: 0xF2F2F7)
        static let grouped    = UIColor(hex: 0xF2F2F7)
        static let groupedSec = UIColor.white
        static let line       = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.29)
        static let lineO      = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.12)
        static let ink        = UIColor.black
        static let inkDim     = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.6)
        static let inkMute    = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.3)
        static let accent     = UIColor(hex: 0x007AFF)
        static let amber      = UIColor(hex: 0xFF9500)
        static let green      = UIColor(hex: 0x34C759)
        static let red        = UIColor(hex: 0xFF3B30)
    }

    // MARK: - Pane State Visuals

    /// State dot colors (consistent across light/dark)
    static let dotWorking  = UIColor(hex: 0x30D158)
    static let dotIdle     = UIColor.systemGray
    static let dotAwaiting = UIColor(hex: 0xFF9F0A)

    // MARK: - Appearance-Adaptive Helpers

    /// Whether the current trait collection is light mode
    static var isLight: Bool {
        UITraitCollection.current.userInterfaceStyle == .light
    }

    /// Current terminal palette based on system appearance
    static var term: (bg: UIColor, bgIdle: UIColor, bgAwait: UIColor, bgWorking: UIColor,
                      fg: UIColor, dim: UIColor, border: UIColor,
                      borderActive: UIColor, borderAwait: UIColor, borderWork: UIColor,
                      awaitInk: UIColor, workInk: UIColor) {
        isLight
            ? (TermLight.bg, TermLight.bgIdle, TermLight.bgAwait, TermLight.bgWorking,
               TermLight.fg, TermLight.dim, TermLight.border,
               TermLight.borderActive, TermLight.borderAwait, TermLight.borderWork,
               TermLight.awaitInk, TermLight.workInk)
            : (TermDark.bg, TermDark.bgIdle, TermDark.bgAwait, TermDark.bgWorking,
               TermDark.fg, TermDark.dim, TermDark.border,
               TermDark.borderActive, TermDark.borderAwait, TermDark.borderWork,
               TermDark.awaitInk, TermDark.workInk)
    }

    /// Background for pane based on state — adapts to light/dark
    static func paneBackground(for state: PaneState) -> UIColor {
        let t = term
        switch state {
        case .awaitingInput: return t.bgAwait
        case .working:       return t.bgWorking
        case .idle:          return t.bgIdle
        }
    }

    /// Border color for pane based on state and active flag
    static func paneBorder(for state: PaneState, active: Bool) -> UIColor {
        let t = term
        if active { return t.borderActive }
        switch state {
        case .awaitingInput: return t.borderAwait.withAlphaComponent(0.5)
        case .working:       return t.borderWork
        case .idle:          return t.border
        }
    }

    /// Border width for active/inactive
    static func paneBorderWidth(active: Bool) -> CGFloat {
        active ? 1.5 : 1.0
    }

    /// Dot color for pane state
    static func dotColor(for state: PaneState) -> UIColor {
        switch state {
        case .working:       return dotWorking
        case .idle:          return dotIdle
        case .awaitingInput: return dotAwaiting
        }
    }

    // MARK: - Glass Pill Style

    /// Glass pill background for dark chrome
    static let glassDark = UIColor(red: 120/255, green: 120/255, blue: 128/255, alpha: 0.32)

    // MARK: - Fonts

    static let mono = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    static let sans = UIFont.systemFont(ofSize: 14, weight: .regular)
    static let display = UIFont.systemFont(ofSize: 34, weight: .bold)

    /// Terminal font size — reads from Settings slider, falls back to device defaults
    static var terminalFontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "terminal_font_size")
        return stored > 0 ? CGFloat(stored) : (UIDevice.current.userInterfaceIdiom == .pad ? 14 : 12)
    }
}

// MARK: - UIColor Hex Initializer

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - SwiftUI Color Bridges

extension Color {
    static let stAccent   = Color(STTheme.ChromeDark.accent)
    static let stAmber    = Color(STTheme.ChromeDark.amber)
    static let stGreen    = Color(STTheme.ChromeDark.green)
    static let stRed      = Color(STTheme.ChromeDark.red)
    static let stInk      = Color(STTheme.ChromeDark.ink)
    static let stInkDim   = Color(STTheme.ChromeDark.inkDim)
    static let stInkMute  = Color(STTheme.ChromeDark.inkMute)
    static let stSurface  = Color(STTheme.ChromeDark.surface)
    static let stSurface2 = Color(STTheme.ChromeDark.surface2)
    static let stLine     = Color(STTheme.ChromeDark.line)
    static let stLineO    = Color(STTheme.ChromeDark.lineO)
    static let stAwaitInk = Color(STTheme.TermDark.awaitInk)
}
