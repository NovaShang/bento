import XCTest
import BentoLink
import BentoTerminalPane
@testable import BentoShellTermMac

// The pane's INTERACTION mode — alternate screen, mouse reporting,
// copy-mode — is the one reading a surface cannot get from the pane's own
// bytes: a program enables the mouse and the alternate screen when it
// starts, and a surface bound later never saw those sequences. So it comes
// from the `tmuxpanes` poll, and everything about how it is merged is
// load-bearing: with these four flags stuck at false the wheel over a
// fullscreen TUI scrolled the terminal's own history instead of reaching
// the program.
@MainActor
final class PaneInteractionModeTests: XCTestCase {

    private func row(_ pane: String, alternate: Bool? = nil, mouseAny: Bool? = nil,
                     mouseSGR: Bool? = nil, inMode: Bool? = nil) -> AcpTmuxPaneStatus {
        AcpTmuxPaneStatus(pane: pane, command: "less", title: "t", path: nil,
                          alternateOn: alternate, mouseAny: mouseAny,
                          mouseSGR: mouseSGR, inMode: inMode)
    }

    func testPollReadingBecomesTheModeTable() {
        let modes = TerminalViewModel.paneModes(
            from: [TmuxPaneID(0): row("%0", alternate: true, mouseAny: true,
                                      mouseSGR: true, inMode: false),
                   TmuxPaneID(1): row("%1")],
            previous: [:])
        XCTAssertEqual(modes[TmuxPaneID(0)],
                       .init(alternateOn: true, mouseAny: true, mouseSGR: true, inMode: false))
        // Absent fields = a daemon too old to report them; the terminal
        // default is off, never a guess.
        XCTAssertEqual(modes[TmuxPaneID(1)], .init())
    }

    func testEmptyPollKeepsTheLastReading() {
        let held: [TmuxPaneID: Pane.InteractionMode] = [
            TmuxPaneID(0): .init(alternateOn: true, mouseAny: true, mouseSGR: false, inMode: false)
        ]
        // A failed poll (daemon briefly unreachable) answers no rows. Reading
        // that as "the TUI exited" would hand the mouse back to selection and
        // put a scrollback under a pane that has none.
        XCTAssertEqual(TerminalViewModel.paneModes(from: [:], previous: held), held)
    }

    func testPaneMissingFromANonEmptyPollIsDropped() {
        let held: [TmuxPaneID: Pane.InteractionMode] = [
            TmuxPaneID(9): .init(alternateOn: true, mouseAny: true, mouseSGR: true, inMode: true)
        ]
        let modes = TerminalViewModel.paneModes(
            from: [TmuxPaneID(0): row("%0")], previous: held)
        // tmux reuses pane numbers — a corpse's mode must not be inherited.
        XCTAssertNil(modes[TmuxPaneID(9)])
        XCTAssertEqual(modes[TmuxPaneID(0)], .init())
    }

    func testInteractionModeRoundTripsThroughAPane() {
        var pane = Pane(id: TmuxPaneID(0), windowID: nil, inActiveWindow: true,
                        x: 0, y: 0, width: 80, height: 24,
                        isActive: true, isZoomed: false, title: nil, currentCommand: nil)
        XCTAssertEqual(pane.interactionMode, .init(), "a mirror row starts plain")
        pane.interactionMode = .init(alternateOn: true, mouseAny: true,
                                     mouseSGR: true, inMode: true)
        XCTAssertTrue(pane.alternateOn && pane.mouseAny && pane.mouseSGR && pane.inMode)
        XCTAssertEqual(pane.interactionMode,
                       .init(alternateOn: true, mouseAny: true, mouseSGR: true, inMode: true))
    }
}
