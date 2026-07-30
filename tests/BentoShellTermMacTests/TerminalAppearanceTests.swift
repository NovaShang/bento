import XCTest
@testable import BentoShellTermMac
@testable import BentoTerminalPane
@testable import BentoUI

/// The renderer takes its theme by injection since BentoTerminalPane was
/// extracted; nothing injected it, so terminals stopped following both the
/// Mac's light/dark and the user's theme pick. These pin the frozen mapping.
final class TerminalAppearanceTests: XCTestCase {
    /// The System theme writes NO palette on purpose: ghostty's own look then
    /// follows the OS appearance, which is what makes the terminal track the
    /// Mac. (Frozen `writeColorConfig` skipped the palette for exactly this id.)
    func testSystemThemeWritesNoPaletteSoGhosttyFollowsTheOS() {
        let system = TerminalColorTheme.find(id: TerminalColorTheme.systemID)
        let appearance = TermShell.appearance(from: system, fontFamily: nil, fontSize: 13)
        XCTAssertNil(appearance.palette)
        XCTAssertTrue(appearance.isDark)
    }

    /// Every other theme — including "System (Light)", which frozen did NOT
    /// exempt — ships its explicit colors.
    func testExplicitThemesShipTheirPalette() {
        let dracula = TerminalColorTheme.find(id: "dracula")
        let appearance = TermShell.appearance(from: dracula, fontFamily: "Menlo", fontSize: 14)
        XCTAssertEqual(appearance.palette?.background, dracula.bg)
        XCTAssertEqual(appearance.palette?.foreground, dracula.fg)
        XCTAssertEqual(appearance.palette?.cursor, dracula.cursor)
        XCTAssertEqual(appearance.palette?.ansi.count, dracula.ansi.count)
        XCTAssertEqual(appearance.fontFamily, "Menlo")
        XCTAssertEqual(appearance.fontSize, 14)
        XCTAssertTrue(appearance.isDark)
    }

    func testSystemLightIsNotExemptAndReportsLight() {
        let light = TerminalColorTheme.find(id: TerminalColorTheme.systemLightID)
        let appearance = TermShell.appearance(from: light, fontFamily: nil, fontSize: 13)
        XCTAssertNotNil(appearance.palette, "only the dark System sentinel defers to ghostty")
        XCTAssertFalse(appearance.isDark, "programs inside the terminal must be told it's light")
    }

    /// The provider must be installed by the path the app actually takes —
    /// the app never calls TermShell.install(); the first TerminalViewModel
    /// calls installPaneModule().
    @MainActor
    func testInstallingTheProviderReplacesTheBuiltInDefault() {
        TermShell.installTerminalAppearance()
        let produced = GhosttyRuntime.appearanceProvider()
        let expected = TermShell.appearance(from: ThemeStore.shared.current,
                                            fontFamily: ThemeStore.shared.ghosttyFontFamily,
                                            fontSize: ThemeStore.shared.fontSize)
        XCTAssertEqual(produced, expected)
    }
}
