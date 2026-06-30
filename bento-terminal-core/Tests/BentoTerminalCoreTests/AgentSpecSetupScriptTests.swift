import XCTest
@testable import BentoTerminalCore

/// Locks the working-directory quoting in `AgentSpec.setupScript`.
///
/// Regression: iOS new sessions defaulted to `~/code`, which got wrapped in
/// single quotes (`-c '~/code'`). The remote shell never expanded the tilde,
/// tmux couldn't find the literal `~/code`, and the session fell back to the
/// server cwd `/`. The fix keeps a leading `~` outside the quotes so the
/// remote login shell expands it to the user's home directory.
final class AgentSpecSetupScriptTests: XCTestCase {

    private func spec(dir: String, panes: Int = 1) -> AgentSpec {
        let layout: TmuxLayout = panes == 1 ? .solo : .sideBySide
        return AgentSpec(sessionName: "work", workingDir: dir, agentCommand: "", layout: layout)
    }

    func testTildePathKeepsTildeUnquotedSoRemoteShellExpands() {
        let script = spec(dir: "~/code").setupScript
        XCTAssertTrue(
            script.contains("-c ~/'code'"),
            "tilde must stay outside the quotes for remote expansion; got: \(script)"
        )
        XCTAssertFalse(
            script.contains("-c '~/code'"),
            "fully-quoted tilde path is the bug that lands the session in /"
        )
    }

    func testBareTildeStaysBare() {
        let script = spec(dir: "~").setupScript
        XCTAssertTrue(script.contains("-c ~"), "got: \(script)")
        XCTAssertFalse(script.contains("-c '~'"), "got: \(script)")
    }

    func testAbsolutePathIsFullyQuoted() {
        // macOS wizard resolves to an absolute path; behavior must be unchanged.
        let script = spec(dir: "/Users/nova/code").setupScript
        XCTAssertTrue(script.contains("-c '/Users/nova/code'"), "got: \(script)")
    }

    func testTildeAppliesToEverySplitPaneToo() {
        let script = spec(dir: "~/code", panes: 2).setupScript
        // Each split-window line must also inherit the expanded directory.
        let splitLines = script.split(separator: ";").filter { $0.contains("split-window") }
        XCTAssertFalse(splitLines.isEmpty, "expected at least one split-window line; got: \(script)")
        for line in splitLines {
            XCTAssertTrue(line.contains("-c ~/'code'"), "split pane lost tilde expansion: \(line)")
        }
    }
}
