import XCTest
import BentoTerminalPane
@testable import BentoShellTermMac

// currentWorkingDirectory keeps the frozen acceptance semantics over the
// trunk's data seam (a fresh tmuxpanes pull instead of the frozen per-pane
// display-message): trimmed, absolute-only, nil when the seam is unwired or
// the daemon answers nothing. This nil/non-nil gate is exactly what the file
// tree's "Working directory unknown" branch and the host's OSC-7 fallback
// key on, so it must not drift.
@MainActor
final class PaneWorkingDirectoryTests: XCTestCase {

    private func makeVM() -> PaneViewModel {
        PaneViewModel(
            pane: Pane(id: TmuxPaneID(0), windowID: nil, inActiveWindow: true,
                       x: 0, y: 0, width: 80, height: 24,
                       isActive: true, isZoomed: false,
                       title: nil, currentCommand: nil),
            runtime: nil)
    }

    func testUnwiredSeamAnswersNil() async {
        let vm = makeVM()
        let got = await vm.currentWorkingDirectory()
        XCTAssertNil(got, "no data seam wired — must answer nil, not a guess")
    }

    func testAbsolutePathPassesTrimmed() async {
        let vm = makeVM()
        vm.fetchWorkingDirectory = { "/Users/me/code\n" }
        let got = await vm.currentWorkingDirectory()
        XCTAssertEqual(got, "/Users/me/code")
    }

    func testNonAbsoluteAnswersRefused() async {
        let vm = makeVM()
        for bad: String? in ["relative/path", "", "   ", nil] {
            vm.fetchWorkingDirectory = { bad }
            let got = await vm.currentWorkingDirectory()
            XCTAssertNil(got, "must refuse \(String(describing: bad))")
        }
    }
}
