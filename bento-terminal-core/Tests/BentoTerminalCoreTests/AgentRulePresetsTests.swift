import XCTest
@testable import BentoTerminalCore

/// Coverage for the non-Claude rule sets (AgentRulePresets.swift). Fixtures are
/// synthesized from the UI strings documented in herdr's detection manifests —
/// the factual evidence source for these agents — so they lock our re-expression
/// to that evidence until we replace them with first-hand captures.
final class AgentRulePresetsTests: XCTestCase {

    private let detector = AgentDetector.shared

    private func set(_ command: String) -> AgentRuleSet {
        guard let s = detector.ruleSet(command: command, title: "") else {
            fatalError("no rule set resolves for command \(command)")
        }
        return s
    }

    // MARK: - Registry

    func testBuiltInsResolveByCommand() {
        for (command, id) in [
            ("claude", "claude-code"), ("codex", "codex"), ("gemini", "gemini"),
            ("opencode", "opencode"), ("hermes", "hermes"), ("agy", "antigravity"),
            ("cursor-agent", "cursor-agent"), ("copilot", "copilot"),
            ("amp", "amp"), ("cline", "cline"),
        ] {
            XCTAssertEqual(detector.ruleSet(command: command, title: "")?.id, id,
                           "command \(command) should resolve rule set \(id)")
        }
        XCTAssertNil(detector.ruleSet(command: "zsh", title: "~/code"))
    }

    func testBuiltInIDsAreUnique() {
        let ids = AgentRuleSet.builtIns.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    /// Every built-in profile that carries agentRules must use the same id for
    /// both — the quick-keys lookup keys `.awaitingInput(profile:)` by it.
    @MainActor
    func testProfileAndRuleSetIDsAgree() {
        for p in ProfileStore.defaultProfiles {
            guard let rules = p.agentRules else { continue }
            XCTAssertEqual(p.id, rules.id, "profile \(p.id) carries rules id \(rules.id)")
        }
    }

    // MARK: - Codex

    func testCodexTitleActionRequiredIsBlocked() {
        let r = detector.classify(set("codex"), title: "Action Required: approve command", snapshot: nil)
        XCTAssertEqual(r?.status, .blocked)
    }

    func testCodexTitleSpinnerIsWorking() {
        let r = detector.classify(set("codex"), title: "⠧ Running tests", snapshot: nil)
        XCTAssertEqual(r?.status, .working)
    }

    func testCodexStrongBlockerBelowPromptMarker() {
        let snapshot = """
        Some earlier prose mentioning press enter to confirm or esc to cancel.
        › fix the build
        Allow command?
          press enter to confirm or esc to cancel
        """
        let r = detector.classify(set("codex"), title: "Codex", snapshot: snapshot)
        XCTAssertEqual(r?.status, .blocked)
        XCTAssertEqual(r?.ruleID, "strong_blocker_form")
    }

    /// The same form text ABOVE the last `›` prompt line is history, not live
    /// UI — the marker-scoped strong rule must not fire (the weak whole-screen
    /// rule may still, at lower priority, but not for this text).
    func testCodexFormAbovePromptMarkerIsNotStrongBlocked() {
        let snapshot = """
        Allow command?
          press enter to confirm or esc to cancel
        › continue please
        ⠋ working on it
        """
        let r = detector.classify(set("codex"), title: "Codex", snapshot: snapshot)
        XCTAssertNotEqual(r?.ruleID, "strong_blocker_form")
    }

    func testCodexNeutralTitleIsIdle() {
        let r = detector.classify(set("codex"), title: "Codex — ~/project", snapshot: "all done\n")
        XCTAssertEqual(r?.status, .idle)
    }

    // MARK: - Gemini

    func testGeminiApplyChangeIsBlocked() {
        let snapshot = """
        │ Apply this change
        │ ● yes, allow once
        """
        XCTAssertEqual(detector.classify(set("gemini"), title: "", snapshot: snapshot)?.status, .blocked)
    }

    func testGeminiEscCancelIsWorking() {
        XCTAssertEqual(detector.classify(set("gemini"), title: "", snapshot: "thinking… (esc to cancel)")?.status, .working)
    }

    // MARK: - OpenCode

    func testOpenCodePermissionRequiredIsBlocked() {
        XCTAssertEqual(detector.classify(set("opencode"), title: "",
                                          snapshot: "△ Permission required\nbash: rm -rf build")?.status, .blocked)
    }

    func testOpenCodeInterruptHintIsWorking() {
        XCTAssertEqual(detector.classify(set("opencode"), title: "",
                                          snapshot: "working…  esc to interrupt")?.status, .working)
    }

    // MARK: - Hermes

    func testHermesDangerousCommandIsBlocked() {
        let snapshot = """
        dangerous command detected
        allow once   allow for this session   deny
        enter to confirm
        """
        XCTAssertEqual(detector.classify(set("hermes"), title: "", snapshot: snapshot)?.status, .blocked)
    }

    // MARK: - Antigravity

    func testAntigravityPermissionIsBlocked() {
        let snapshot = """
        requesting permission for: rm -rf build
        do you want to proceed?
        """
        XCTAssertEqual(detector.classify(set("agy"), title: "", snapshot: snapshot)?.status, .blocked)
    }

    func testAntigravitySpinnerLineIsWorking() {
        XCTAssertEqual(detector.classify(set("agy"), title: "",
                                          snapshot: "⠸⠼ Thinking about the plan")?.status, .working)
    }

    // MARK: - Cursor Agent

    func testCursorWriteApprovalIsBlocked() {
        let snapshot = """
        write to this file? src/main.rs
        proceed (y)   reject & propose changes
        """
        let r = detector.classify(set("cursor-agent"), title: "", snapshot: snapshot)
        XCTAssertEqual(r?.status, .blocked)
        XCTAssertEqual(r?.ruleID, "write_file_approval")
    }

    func testCursorStopHintIsWorking() {
        XCTAssertEqual(detector.classify(set("cursor-agent"), title: "",
                                          snapshot: "generating…  ctrl+c to stop")?.status, .working)
    }

    // MARK: - Copilot (blocked outranks working on the shared esc-cancel hint)

    func testCopilotSelectionFormBeatsWorkingHint() {
        let snapshot = """
        Choose an option
        ↑/↓ move · enter to select · esc to cancel
        """
        XCTAssertEqual(detector.classify(set("copilot"), title: "", snapshot: snapshot)?.status, .blocked)
    }

    func testCopilotCancelHintAloneIsWorking() {
        XCTAssertEqual(detector.classify(set("copilot"), title: "",
                                          snapshot: "running tools… esc to cancel")?.status, .working)
    }

    // MARK: - Amp / Cline

    func testAmpApprovalFooterIsBlocked() {
        XCTAssertEqual(detector.classify(set("amp"), title: "",
                                          snapshot: "waiting for approval — run this command?")?.status, .blocked)
    }

    func testClineToolPermissionIsBlocked() {
        XCTAssertEqual(detector.classify(set("cline"), title: "",
                                          snapshot: "Let Cline use this tool?  yes / no")?.status, .blocked)
    }

    /// Cline has no working/idle rules on purpose — unmatched panes fall back
    /// to output-activity detection.
    func testClineQuietScreenMatchesNothing() {
        XCTAssertNil(detector.classify(set("cline"), title: "", snapshot: "just prose\n"))
    }

    // MARK: - Claude additions (transcript / picker skips, bash permission)

    private func claude() -> AgentRuleSet { set("claude") }

    func testClaudeTranscriptViewerIsSkip() {
        let snapshot = """
        lots of transcript text
        showing detailed transcript · ctrl+o to toggle
        """
        let r = detector.classify(claude(), title: "x", snapshot: snapshot)
        XCTAssertEqual(r?.ruleID, "transcript_viewer")
        XCTAssertNil(r?.status, "transcript viewer must be a skip rule (state unchanged)")
    }

    func testClaudeBashPermissionIsBlocked() {
        let snapshot = """
        Bash command
          rm -rf build/
        Do you want to proceed?
        ❯ 1. Yes
          2. No, and tell Claude what to do differently (tab to amend)
        """
        let r = detector.classify(claude(), title: "x", snapshot: snapshot)
        XCTAssertEqual(r?.status, .blocked)
    }

    func testClaudeModelPickerIsSkip() {
        let snapshot = """
        Select model
        1. Sonnet    2. Opus
        enter to set as default · esc to cancel
        """
        let r = detector.classify(claude(), title: "x", snapshot: snapshot)
        XCTAssertEqual(r?.ruleID, "model_picker")
        XCTAssertNil(r?.status)
    }
}
