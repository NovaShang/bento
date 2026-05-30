import UIKit
import SwiftUI
import BentoTerminalCore

// MARK: - Design Tokens

/// Centralized design tokens matching the Bento design prototype.
/// iOS system color palette + terminal dark/light themes.
enum STTheme {

    // MARK: - Terminal Palettes

    /// Dark terminal theme — bento brand palette (icon prompt cell as
    /// pane background; emerald/salmon for state).
    enum TermDark {
        static let bg          = UIColor(hex: 0x0D0F13)   // bentoInset
        static let bgIdle      = UIColor(hex: 0x0D0F13)
        static let bgAwait     = UIColor(hex: 0x2A1F10)
        static let bgWorking   = UIColor(hex: 0x0C3320)
        static let fg          = UIColor(hex: 0xF0EAD8)   // bento rice ink
        static let dim         = UIColor(hex: 0x9CA0AB)
        static let muted       = UIColor(hex: 0x5A5F6B)
        static let border      = UIColor.white.withAlphaComponent(0.06)
        static let borderActive = UIColor(hex: 0x4ADE80)  // bento emerald
        static let borderAwait = UIColor(hex: 0xE89B7C)   // bento salmon
        static let borderWork  = UIColor(hex: 0x4ADE80).withAlphaComponent(0.30)
        static let awaitInk    = UIColor(hex: 0xE89B7C)
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

    /// User-selected terminal font, falling back to SF Mono.
    static var terminalFont: UIFont {
        let size = terminalFontSize
        let family = UserDefaults.standard.string(forKey: "terminal_font_family") ?? "maple-nf-cn"
        switch family {
        case "menlo":
            return UIFont(name: "Menlo-Regular", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "courier":
            return UIFont(name: "CourierNewPSMT", size: size)
                ?? UIFont(name: "Courier", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "jetbrains":
            return UIFont(name: "JetBrainsMono-Regular", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "maple-nf-cn":
            return UIFont(name: "MapleMono-NF-CN-Regular", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "system-medium":
            return UIFont.monospacedSystemFont(ofSize: size, weight: .medium)
        default:
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
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

// MARK: - Bento Brand Tokens
//
// Palette pulled directly from docs/bento-icon.svg — cold IDE-grey shell
// holding warm content cells (emerald prompt, salmon, rice-white, veg-green).
// No invented colors. Chrome stays GUI-clean; mono is reserved for places
// where monospace is literally true (host strings, terminal contents).

enum BentoBrand {
    // Frame — cold shell + recessed pane
    static let shell      = UIColor(hex: 0x16181D)  // icon outer shell
    static let surface    = UIColor(hex: 0x1E222B)  // elevated card
    static let surfaceHi  = UIColor(hex: 0x262B36)  // pressed / inner chip
    static let inset      = UIColor(hex: 0x0D0F13)  // icon prompt cell (recessed)
    static let border     = UIColor(hex: 0x2A2E38)
    static let borderHi   = UIColor(hex: 0x363B47)

    // Ink — rice-white-leaning warm for primary text
    static let inkPrimary   = UIColor(hex: 0xF0EAD8)
    static let inkSecondary = UIColor(hex: 0x9CA0AB)
    static let inkMuted     = UIColor(hex: 0x5A5F6B)

    // Brand cells — straight from the icon
    static let emerald = UIColor(hex: 0x4ADE80)  // prompt / connected / cursor
    static let salmon  = UIColor(hex: 0xE89B7C)  // warm / awaiting / voice
    static let rice    = UIColor(hex: 0xF0EAD8)
    static let veg     = UIColor(hex: 0x6FA254)  // category / relay / Mac
    static let vegDeep = UIColor(hex: 0x4D7C3F)
    static let red     = UIColor(hex: 0xFF5A52)
}

/// Call once at app launch to harmonize UIKit-backed surfaces (nav bars,
/// tab bars, table sections) with the bento palette. SwiftUI alone can't
/// reach grouped-list section headers and inset table backgrounds, so we
/// drive them through UIAppearance.
@MainActor
enum BentoAppearance {
    static func install() {
        let shell = BentoBrand.shell
        let surface = BentoBrand.surface
        let ink = BentoBrand.inkPrimary

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = shell
        nav.titleTextAttributes = [.foregroundColor: ink]
        nav.largeTitleTextAttributes = [.foregroundColor: ink]
        nav.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = BentoBrand.emerald

        UITableView.appearance().backgroundColor = shell
        UITableView.appearance().separatorColor = BentoBrand.border
        UITableView.appearance().sectionHeaderTopPadding = 12
        UITableViewCell.appearance().backgroundColor = surface
        UITextField.appearance().textColor = ink
        UITextField.appearance().keyboardAppearance = .dark

        let toolbar = UIToolbarAppearance()
        toolbar.configureWithOpaqueBackground()
        toolbar.backgroundColor = shell
        UIToolbar.appearance().standardAppearance = toolbar
        UIToolbar.appearance().scrollEdgeAppearance = toolbar
    }
}

// MARK: - Reusable view modifiers

extension View {
    /// Apply to a `Form` or sheet content to drop the system grouped-list
    /// chrome and use bento tokens instead.
    func bentoForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.bentoShell.ignoresSafeArea())
            .tint(Color.bentoEmerald)
    }

    /// Apply to a `Section` (or individual rows) so the row sits on the
    /// bento surface card instead of iOS system grouped white.
    func bentoFormRow() -> some View {
        self.listRowBackground(Color.bentoSurface)
    }

    /// Apply on a `Form` `Section`: rows render on the bento surface with
    /// subtle separators in bento border color. Uses native iOS grouped
    /// styling (rows joined into a section panel) — the design language
    /// is "native iOS chrome, recolored to bento", not custom cards.
    func bentoSectionStyle() -> some View {
        self
            .listRowBackground(Color.bentoSurface)
            .listRowSeparatorTint(Color.bentoBorder)
    }

    /// Big primary CTA (emerald fill, black ink). Used for "Pair Your Mac",
    /// "Get started", "Launch", etc.
    func bentoPrimaryButton() -> some View {
        self.buttonStyle(BentoPrimaryButtonStyle())
    }

    /// Outlined secondary CTA (bento surface fill, ink text, subtle border).
    func bentoSecondaryButton() -> some View {
        self.buttonStyle(BentoSecondaryButtonStyle())
    }
}

struct BentoPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.bentoEmerald)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
    }
}

struct BentoSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.bentoInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.bentoSurface)
                    .opacity(configuration.isPressed ? 0.7 : 1.0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1)
            )
    }
}

extension Color {
    static let bentoShell      = Color(BentoBrand.shell)
    static let bentoSurface    = Color(BentoBrand.surface)
    static let bentoSurfaceHi  = Color(BentoBrand.surfaceHi)
    static let bentoInset      = Color(BentoBrand.inset)
    static let bentoBorder     = Color(BentoBrand.border)
    static let bentoBorderHi   = Color(BentoBrand.borderHi)
    static let bentoInk        = Color(BentoBrand.inkPrimary)
    static let bentoInkDim     = Color(BentoBrand.inkSecondary)
    static let bentoInkMute    = Color(BentoBrand.inkMuted)
    static let bentoEmerald    = Color(BentoBrand.emerald)
    static let bentoSalmon     = Color(BentoBrand.salmon)
    static let bentoRice       = Color(BentoBrand.rice)
    static let bentoVeg        = Color(BentoBrand.veg)
    static let bentoVegDeep    = Color(BentoBrand.vegDeep)
    static let bentoRed        = Color(BentoBrand.red)
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
