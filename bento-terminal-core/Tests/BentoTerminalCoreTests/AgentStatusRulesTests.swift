import XCTest
@testable import BentoTerminalCore

/// Fixtures are trimmed from real `tmux capture-pane` output of a live Claude
/// Code session (2026-06-21), so these lock the rules to actual UI, not guesses.
final class AgentStatusRulesTests: XCTestCase {

    private let detector = AgentDetector.shared

    private func claude() -> AgentRuleSet {
        let set = detector.ruleSet(command: "claude", title: "✳ anything")
        XCTAssertNotNil(set, "claude command should resolve the Claude rule set")
        return set!
    }

    // Real idle screen: empty ❯ box between two rules, footer has the mode hint.
    private let idleSnapshot = """
      ◼ build + 浏览器验证各门窗类型 + 提交 PR 部署

    ────────────────────────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle) · ctrl+t to hide tasks · ← for age…
    """

    // Real working screen: live status line + `esc to interrupt` in the footer.
    private let workingSnapshot = """
    · Inferring… (1m 12s · ↓ 4.2k tokens)
    ────────────────────────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt   Update available!
    """

    func testIdentityByCommand() {
        XCTAssertNotNil(detector.ruleSet(command: "claude", title: ""))
        XCTAssertNil(detector.ruleSet(command: "zsh", title: "~/code"))
        XCTAssertNil(detector.ruleSet(command: nil, title: "Shangs-Air-2"))
    }

    func testTitleSpinnerIsWorking_noSnapshotNeeded() {
        // Braille spinner prefix → working, decided from the title alone.
        let r = detector.classify(claude(), title: "⠐ Diagnose Mac typing lag", snapshot: nil)
        XCTAssertEqual(r?.status, .working)
        XCTAssertEqual(r?.ruleID, "title_working_spinner")
    }

    func testTitleStarIsIdle() {
        let r = detector.classify(claude(), title: "✳ Define scope", snapshot: idleSnapshot)
        XCTAssertEqual(r?.status, .idle)
    }

    func testIdlePromptBoxFromRealSnapshot() {
        // Even with a neutral title, the empty ❯ box → idle.
        let r = detector.classify(claude(), title: "Define scope", snapshot: idleSnapshot)
        XCTAssertEqual(r?.status, .idle)
        XCTAssertEqual(r?.ruleID, "idle_prompt_box")
    }

    func testWorkingFooterBeatsIdlePromptBox() {
        // The working footer (`esc to interrupt`) outranks the ❯ box → working,
        // even though an empty ❯ is also on screen.
        let r = detector.classify(claude(), title: "Diagnose", snapshot: workingSnapshot)
        XCTAssertEqual(r?.status, .working)
        XCTAssertEqual(r?.ruleID, "footer_working")
    }

    func testPermissionPromptIsBlocked() {
        // Provisional blocked fixture (calibrate against a live capture).
        let blocked = """
        ╭──────────────────────────────────────────────╮
        │ Bash command                                   │
        │ rm -rf build/                                   │
        │                                                │
        │ Do you want to proceed?                        │
        │ ❯ 1. Yes                                       │
        │   2. No, and tell Claude what to do (esc)      │
        ╰──────────────────────────────────────────────╯
          esc to cancel
        """
        let r = detector.classify(claude(), title: "✳ task", snapshot: blocked)
        XCTAssertEqual(r?.status, .blocked)
    }

    func testHorizontalRuleDetection() {
        XCTAssertTrue(AgentDetector.isHorizontalRule(String(repeating: "─", count: 40)))
        XCTAssertTrue(AgentDetector.isHorizontalRule("  " + String(repeating: "─", count: 20)))
        XCTAssertFalse(AgentDetector.isHorizontalRule("❯ hello world"))
        XCTAssertFalse(AgentDetector.isHorizontalRule("── short"))
    }
}
