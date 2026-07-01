import XCTest
@testable import BentoTerminalCore

/// Fixture mirrors a real Claude Code scrollback (PTY capture 2026-06-30): user
/// turns render as `❯ ` lines; assistant lines start `⏺`, status `✻`, and the
/// empty live prompt is `❯`+NBSP (must NOT count as a turn).
final class TurnNavigatorTests: XCTestCase {

    private let scrollback = [
        "\u{276F} In one short line, output ALPHA",      // 0  ← user turn
        "",                                               // 1
        "\u{23FA} ALPHA",                                 // 2  assistant
        "",                                               // 3
        "\u{273B} Worked for 3s",                         // 4  status
        "",                                               // 5
        "\u{276F} In one short line, output BRAVO",       // 6  ← user turn
        "",                                               // 7
        "\u{23FA} BRAVO",                                 // 8
        "",                                               // 9
        "\u{276F} In one short line, output CHARLIE",     // 10 ← user turn
        "",                                               // 11
        "\u{23FA} CHARLIE",                               // 12
        String(repeating: "\u{2500}", count: 40),         // 13 rule
        "\u{276F}\u{00A0}",                               // 14 empty live prompt (NBSP)
        String(repeating: "\u{2500}", count: 40),         // 15 rule
    ].joined(separator: "\n")

    private let boundary = ["^\\s*\\x{276F}\\x{20}"]   // ProfileStore.claudeCode.promptBoundary

    func testFindsUserTurnsNotPromptOrAssistant() {
        var nav = TurnNavigator()
        nav.scan(scrollback: scrollback, boundaryPatterns: boundary)
        XCTAssertEqual(nav.boundaries, [0, 6, 10], "only the 3 `❯ ` user turns")
    }

    func testNavigationWalksOneTurnPerStep() {
        var nav = TurnNavigator()
        nav.scan(scrollback: scrollback, boundaryPatterns: boundary)
        // From the live bottom (row 14), repeated "up" steps back turn by turn.
        XCTAssertEqual(nav.boundaryAbove(14), 10)
        XCTAssertEqual(nav.boundaryAbove(10), 6)
        XCTAssertEqual(nav.boundaryAbove(6), 0)
        XCTAssertNil(nav.boundaryAbove(0))           // oldest → no further up
        // "Down" walks forward.
        XCTAssertEqual(nav.boundaryBelow(0), 6)
        XCTAssertEqual(nav.boundaryBelow(6), 10)
        XCTAssertNil(nav.boundaryBelow(10))          // newest → none below
    }

    func testAvailability() {
        var nav = TurnNavigator()
        nav.scan(scrollback: scrollback, boundaryPatterns: boundary)
        XCTAssertTrue(nav.canJumpUp(viewportTopRow: 14))
        XCTAssertFalse(nav.canJumpUp(viewportTopRow: 0))
        XCTAssertFalse(nav.canJumpDown(viewportTopRow: 10, atBottom: true))   // newest + live
        XCTAssertTrue(nav.canJumpDown(viewportTopRow: 10, atBottom: false))   // scrolled up → toward live
        XCTAssertTrue(nav.canJumpDown(viewportTopRow: 0, atBottom: false))
    }

    func testEmptyPatternsYieldNoBoundaries() {
        var nav = TurnNavigator()
        nav.scan(scrollback: scrollback, boundaryPatterns: [])
        XCTAssertTrue(nav.boundaries.isEmpty)
    }
}
