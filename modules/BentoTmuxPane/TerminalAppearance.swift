import BentoTerminalPane
import BentoUI
import Foundation

/// Feeds the rendering base the theme facts it used to read for itself.
///
/// The frozen runtime called `ThemeStore.shared` directly; extracting
/// BentoTerminalPane replaced that with an injected provider so the renderer
/// depends on no theme store — but for a while nothing injected it, and every
/// surface ran on the provider's built-in default, so terminals followed
/// neither the OS appearance nor the user's theme pick.
///
/// Both tmux shells install this (macOS `TermShell`, the iOS app's
/// `TmuxShell`), which is why it lives here rather than in either of them.
@MainActor
public enum TerminalAppearance {
    /// Point the renderer at the shared theme store. Must run before the first
    /// surface exists: the runtime is a lazy singleton whose first surface
    /// writes the color config. Idempotent.
    public static func install() {
        GhosttyRuntime.appearanceProvider = {
            let store = ThemeStore.shared
            return appearance(from: store.current,
                              fontFamily: store.ghosttyFontFamily,
                              fontSize: store.fontSize)
        }
    }

    /// The theme → renderer mapping, pure so tests can pin the System rule.
    ///
    /// Frozen semantics, verbatim: the dark "System" sentinel writes NO palette
    /// so ghostty's own look follows the OS appearance — that is what makes the
    /// terminal track the Mac — while every other theme, "System (Light)"
    /// included, ships its explicit colors. `isDark` always rides along so
    /// programs inside the terminal get the right color-scheme report.
    nonisolated public static func appearance(from theme: TerminalColorTheme,
                                              fontFamily: String?,
                                              fontSize: Double) -> GhosttyRuntimeAppearance
    {
        let palette: GhosttyRuntimeAppearance.Palette? =
            theme.id == TerminalColorTheme.systemID
            ? nil
            : .init(background: theme.bg, foreground: theme.fg,
                    cursor: theme.cursor, ansi: theme.ansi)
        return GhosttyRuntimeAppearance(palette: palette,
                                        fontFamily: fontFamily,
                                        fontSize: fontSize,
                                        isDark: theme.isDark)
    }
}
