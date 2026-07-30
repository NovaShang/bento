import Foundation

/// The strings and SF Symbol names the host-scoped menu rows render.
///
/// Split out from the views so they can be asserted in tests without a menu:
/// these are the exact literals both Mac apps have shown since before the
/// extraction, and the point of BentoMenuKit is that they can now only change
/// in one place (docs/menubar-unification.md §3).
public enum DaemonMenuPresentation {
    /// Header row. Nil status means the CLI couldn't reach the daemon at all.
    public static func statusLine(_ status: DaemonStatus?) -> String {
        guard let status else { return "Daemon not running" }
        if status.relayConnected {
            return "Connected · \(status.pairedDevices) device\(status.pairedDevices == 1 ? "" : "s")"
        }
        return "Daemon up · relay offline"
    }

    public static func statusSymbol(_ status: DaemonStatus?) -> String {
        guard let status else { return "xmark.circle" }
        return status.relayConnected ? "wifi" : "wifi.exclamationmark"
    }

    /// Second header row — only shown when the daemon reported an id.
    public static func daemonIDLine(_ daemonID: String) -> String {
        "daemon \(daemonID.prefix(8))…"
    }
}

/// Engine (daemon binary) update detection and the cost of acting on it.
///
/// The engine is a separate long-lived process, so replacing the .app does not
/// replace it — this is what turns "I updated but nothing changed" into a
/// visible, one-click state.
public enum EngineUpdate {
    /// Whether the running daemon is executing a different binary than the one
    /// this app would launch.
    ///
    /// We compare binary hashes rather than version strings because every local
    /// build reports the same version, which would make the check permanently
    /// blind. A daemon that reports no hash at all is treated as stale: it
    /// predates this field, so it is by definition older than the app asking.
    /// The one case we stay silent on is not knowing our own answer — if the
    /// helper we would launch can't be hashed, nagging would be guessing.
    public static func isPending(daemonHash: String?, targetHash: String?) -> Bool {
        guard let targetHash else { return false }
        return daemonHash != targetHash
    }

    /// Second line of the update prompt: the cost, before the click rather
    /// than only in the confirmation sheet, so an agent mid-turn is visible
    /// to someone just glancing at the menu.
    public static func hint(liveAgents: Int) -> String {
        guard liveAgents > 0 else { return "The background engine is still the old version" }
        return "Ends \(liveAgents) running agent session\(liveAgents == 1 ? "" : "s")"
    }

    /// Spell out what a restart costs. Zero live agents is the common case
    /// right after an update and deserves to read as harmless, because it is.
    public static func restartCost(live: Int, busy: Int) -> String {
        guard live > 0 else {
            return "No agents are running, so nothing will be interrupted. "
                + "This swaps in the engine that shipped with this version of Bento."
        }
        let agents = "\(live) running agent session\(live == 1 ? "" : "s")"
        let midTurn = busy > 0 ? " \(busy) of them \(busy == 1 ? "is" : "are") mid-turn." : ""
        return "This ends \(agents) — their processes are hosted by the engine "
            + "and cannot survive it.\(midTurn) Your conversation history is kept."
    }
}
