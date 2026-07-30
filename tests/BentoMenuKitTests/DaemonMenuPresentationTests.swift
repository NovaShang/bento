import XCTest
@testable import BentoMenuKit

/// These strings are what the menu bar says. They were byte-identical in both
/// Mac apps before the extraction and must stay that way — the whole point of
/// moving them into BentoMenuKit is that neither product's menu can drift
/// without this failing (docs/menubar-unification.md §3).
final class DaemonMenuPresentationTests: XCTestCase {

    private func status(
        relayConnected: Bool = true,
        pairedDevices: Int = 0,
        daemonID: String? = "a1b2c3d4e5f6",
        exeHash: String? = nil
    ) -> DaemonStatus {
        DaemonStatus(
            version: "0.1.1", pid: 42, uptimeSec: 90,
            relayURL: "https://relay.bentoai.dev",
            relayConnected: relayConnected,
            daemonID: daemonID,
            pairedDevices: pairedDevices,
            exeHash: exeHash
        )
    }

    // MARK: - status header

    func testNoStatusMeansDaemonNotRunning() {
        XCTAssertEqual(DaemonMenuPresentation.statusLine(nil), "Daemon not running")
        XCTAssertEqual(DaemonMenuPresentation.statusSymbol(nil), "xmark.circle")
    }

    func testConnectedCountsDevicesAndPluralizes() {
        XCTAssertEqual(
            DaemonMenuPresentation.statusLine(status(pairedDevices: 0)),
            "Connected · 0 devices"
        )
        XCTAssertEqual(
            DaemonMenuPresentation.statusLine(status(pairedDevices: 1)),
            "Connected · 1 device"
        )
        XCTAssertEqual(
            DaemonMenuPresentation.statusLine(status(pairedDevices: 2)),
            "Connected · 2 devices"
        )
        XCTAssertEqual(DaemonMenuPresentation.statusSymbol(status()), "wifi")
    }

    /// Daemon up but relay down is its own state: the phone can't reach this
    /// Mac, but nothing local is broken.
    func testDaemonUpWithRelayOffline() {
        XCTAssertEqual(
            DaemonMenuPresentation.statusLine(status(relayConnected: false, pairedDevices: 3)),
            "Daemon up · relay offline"
        )
        XCTAssertEqual(
            DaemonMenuPresentation.statusSymbol(status(relayConnected: false)),
            "wifi.exclamationmark"
        )
    }

    func testDaemonIDIsTruncatedToEightWithEllipsis() {
        XCTAssertEqual(DaemonMenuPresentation.daemonIDLine("a1b2c3d4e5f6"), "daemon a1b2c3d4…")
        XCTAssertEqual(DaemonMenuPresentation.daemonIDLine("short"), "daemon short…")
    }

    // MARK: - decoding

    /// The four engine-update fields are optional because a daemon older than
    /// the feature omits them, and a failed decode would read as "daemon down"
    /// and trip the app's watchdog into force-restarting a healthy daemon.
    func testStatusDecodesWithoutTheEngineUpdateFields() throws {
        let json = """
        {"version":"0.1.0","pid":7,"uptime_sec":12,"relay_url":null,
         "relay_connected":false,"daemon_id":"abc","paired_devices":1}
        """
        let decoded = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertNil(decoded.exeHash)
        XCTAssertNil(decoded.liveAgents)
        XCTAssertEqual(decoded.pairedDevices, 1)
        XCTAssertEqual(DaemonMenuPresentation.statusLine(decoded), "Daemon up · relay offline")
    }

    // MARK: - engine skew

    /// No target hash → we can't hash the helper we would launch, so nagging
    /// would be guessing. Stay silent.
    func testUnknownTargetHashNeverPrompts() {
        XCTAssertFalse(EngineUpdate.isPending(daemonHash: "abc", targetHash: nil))
        XCTAssertFalse(EngineUpdate.isPending(daemonHash: nil, targetHash: nil))
    }

    /// A daemon that reports no hash predates the field, so it is by
    /// definition older than the app asking for one.
    func testDaemonWithoutAHashIsTreatedAsStale() {
        XCTAssertTrue(EngineUpdate.isPending(daemonHash: nil, targetHash: "abc"))
    }

    func testMatchingHashesMeanNoUpdate() {
        XCTAssertFalse(EngineUpdate.isPending(daemonHash: "abc", targetHash: "abc"))
        XCTAssertTrue(EngineUpdate.isPending(daemonHash: "old", targetHash: "new"))
    }

    // MARK: - the cost of a restart

    func testUpdateHintNamesTheCostBeforeTheClick() {
        XCTAssertEqual(
            EngineUpdate.hint(liveAgents: 0),
            "The background engine is still the old version"
        )
        XCTAssertEqual(EngineUpdate.hint(liveAgents: 1), "Ends 1 running agent session")
        XCTAssertEqual(EngineUpdate.hint(liveAgents: 4), "Ends 4 running agent sessions")
    }

    func testRestartCostReadsHarmlessWhenNothingIsRunning() {
        XCTAssertEqual(
            EngineUpdate.restartCost(live: 0, busy: 0),
            "No agents are running, so nothing will be interrupted. "
                + "This swaps in the engine that shipped with this version of Bento."
        )
    }

    func testRestartCostNamesAgentsAndMidTurnWork() {
        XCTAssertEqual(
            EngineUpdate.restartCost(live: 1, busy: 0),
            "This ends 1 running agent session — their processes are hosted by the engine "
                + "and cannot survive it. Your conversation history is kept."
        )
        XCTAssertEqual(
            EngineUpdate.restartCost(live: 3, busy: 1),
            "This ends 3 running agent sessions — their processes are hosted by the engine "
                + "and cannot survive it. 1 of them is mid-turn. Your conversation history is kept."
        )
        XCTAssertEqual(
            EngineUpdate.restartCost(live: 3, busy: 2),
            "This ends 3 running agent sessions — their processes are hosted by the engine "
                + "and cannot survive it. 2 of them are mid-turn. Your conversation history is kept."
        )
    }

    // MARK: - relative activity

    func testRelativeActivity() {
        XCTAssertEqual(relativeActivity(.distantPast), "—")
        XCTAssertEqual(relativeActivity(Date()), "just now")
        XCTAssertEqual(relativeActivity(Date().addingTimeInterval(-30)), "just now")
        // Beyond a minute we hand off to RelativeDateTimeFormatter, whose exact
        // wording is locale-dependent; assert only that it stopped saying "just
        // now" and produced something.
        let older = relativeActivity(Date().addingTimeInterval(-3600))
        XCTAssertNotEqual(older, "just now")
        XCTAssertFalse(older.isEmpty)
    }
}
