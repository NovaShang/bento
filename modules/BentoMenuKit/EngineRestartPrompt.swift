#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// The two modal prompts that guard an engine swap.
///
/// HOST-scoped: restarting `bento-daemon` kills the hosted processes of BOTH
/// products, so the sentence that names the cost has to be one sentence, not
/// one per app. The orchestration around it (what to re-sync afterwards) stays
/// in each app — that part is product-specific.
public enum EngineRestartPrompt {
    /// Ask, naming the cost in the user's own terms — how many agents die —
    /// because that is the entire reason this isn't automatic.
    /// Returns true when the user chose to go ahead.
    @MainActor
    public static func confirm(live: Int, busy: Int) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Restart the Bento engine?"
        alert.informativeText = EngineUpdate.restartCost(live: live, busy: busy)
        alert.addButton(withTitle: "Restart engine")
        alert.addButton(withTitle: "Not now")
        // Destructive when work is actually at stake; a plain choice when not.
        if live > 0 { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    public static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't restart the engine"
        alert.informativeText = "\(error.localizedDescription)\n\n"
            + "The old engine may still be running. You can retry, or run "
            + "`bento tunnel stop && bento tunnel start` in Terminal."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#endif
