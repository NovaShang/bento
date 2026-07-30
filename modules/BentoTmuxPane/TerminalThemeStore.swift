// Ported from frozen TerminalThemeStore.swift @ 8fa54b6^; data layer swapped, UI verbatim.
//
// The theme store itself moved to the trunk (BentoUI.ThemeStore — same class,
// same UserDefaults keys, ported from this file's frozen original); what the
// trunk dropped is the terminal-specific tail — the font prefs and the
// TerminalTheme builder every surface is created from. That tail lives on
// here, verbatim, as an extension.
//
// It sits in BentoTmuxPane rather than either shell because BOTH tmux shells
// (macOS BentoShellTermMac, the iOS app) need it and both already depend on
// this module — it is the lowest point that sees ThemeStore (BentoUI) and
// TerminalTheme (BentoTerminalPane) at once, so neither dependency arrow has
// to be inverted and neither shell has to keep its own copy.

import Foundation
import BentoTerminalPane
import BentoUI
#if canImport(UIKit)
import UIKit
#endif

/// Last non-zero size this process read from defaults. UserDefaults can
/// transiently read EMPTY right after device unlock (the prefs plist is
/// protected until first post-unlock read); a config reload in that window
/// must answer with the real size, not the fallback, or every live surface
/// snaps to the wrong font. Mirrors STTheme.terminalFontSize's cache.
/// (A stored property can't live on an extension, so the frozen class's
/// `private var` is a file-private static here — same per-process semantics.)
@MainActor private var lastKnownFontSize: Double = 0

@MainActor
public extension ThemeStore {
    // MARK: Font prefs (same UserDefaults keys both platforms use)

    /// Terminal font size in points. Falls back to the last value this process
    /// saw, then to the platform default — which must match what the app
    /// targets use to CREATE surfaces (iPad 14 / iPhone 12 / mac 13), or a
    /// config reload nudges untouched-slider installs to a different size.
    var fontSize: Double {
        let v = UserDefaults.standard.double(forKey: "terminal_font_size")
        if v > 0 {
            lastKnownFontSize = v
            return v
        }
        if lastKnownFontSize > 0 { return lastKnownFontSize }
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? 14 : 12
        #else
        return 13
        #endif
    }

    /// Selected font-family token (e.g. "jetbrains"); nil = engine default.
    var fontFamilyToken: String? {
        UserDefaults.standard.string(forKey: "terminal_font_family")
    }

    /// ghostty font-family name for the selected token, or nil for the default.
    var ghosttyFontFamily: String? {
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
    func makeTerminalTheme() -> TerminalTheme {
        TerminalTheme(background: current.bg, foreground: current.fg,
                      ansi: current.ansi, fontSize: fontSize, fontFamily: ghosttyFontFamily,
                      isDark: current.isDark)
    }
}
