import XCTest
import BentoWorkbench
@testable import BentoTmuxPane

/// Golden wire shapes for the structure verb encoding, one per verb kind.
/// The expected strings are the JSON the Go decoder reads — field names
/// from daemon/internal/acphost/tmuxstructure.go's StructureVerb tags, the
/// frame from proto.go's documented `{"op":"structure","target":"local",
/// "verb":{…}}` — re-keyed only by the encoder's deterministic sort. A
/// mistake here is SILENT: an unknown key is ignored and the field decodes
/// to its Go zero value, so the daemon would run a subtly different verb
/// and neither side would log anything.
final class DaemonStructureVerbEncodingTests: XCTestCase {
    private func frame(_ verb: StructureVerb, target: String = "") throws -> String {
        let data = try DaemonStructureVerbEncoding(target: target).encodeStructureFrame(verb)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Frame envelope

    func testTargetRidesTheFrameNotTheVerb() throws {
        // proto.go: {"op":"structure","target":"local","verb":{"kind":…}}
        XCTAssertEqual(
            try frame(.killPane(pane: 5), target: "local"),
            #"{"op":"structure","target":"local","verb":{"kind":"killPane","pane":5}}"#)
        // "" is omitted — the daemon defaults an absent target to "local".
        XCTAssertEqual(
            try frame(.killPane(pane: 5)),
            #"{"op":"structure","verb":{"kind":"killPane","pane":5}}"#)
    }

    // MARK: Session verbs

    func testCreateSession() throws {
        XCTAssertEqual(
            try frame(.createSession(name: "dev", cwd: "/tmp/w")),
            #"{"op":"structure","verb":{"cwd":"/tmp/w","kind":"createSession","name":"dev"}}"#)
    }

    func testKillSession() throws {
        XCTAssertEqual(
            try frame(.killSession(name: "dev")),
            #"{"op":"structure","verb":{"kind":"killSession","name":"dev"}}"#)
    }

    func testRenameSession() throws {
        XCTAssertEqual(
            try frame(.renameSession(name: "bento", to: "workbench")),
            #"{"op":"structure","verb":{"kind":"renameSession","name":"bento","to":"workbench"}}"#)
    }

    // MARK: Pane creation

    func testSplitPaneHorizontal() throws {
        // Pane %0 splits: `target` must be EXPLICIT — an omitted 0 would be
        // indistinguishable from "no target named", which happens to decode
        // the same today but reads as an accident. Ints a verb carries are
        // always written.
        XCTAssertEqual(
            try frame(.splitPane(session: "work", target: 0, horizontal: true,
                                 cwd: nil, command: nil)),
            #"{"op":"structure","verb":{"horizontal":true,"kind":"splitPane","session":"work","target":0}}"#)
    }

    func testSplitPaneVerticalWithCwdAndCommand() throws {
        // horizontal:false is the Go zero value — omitted, like omitempty.
        XCTAssertEqual(
            try frame(.splitPane(session: "", target: 3, horizontal: false,
                                 cwd: "/tmp/w", command: "htop")),
            #"{"op":"structure","verb":{"command":"htop","cwd":"/tmp/w","kind":"splitPane","target":3}}"#)
    }

    func testNewPane() throws {
        XCTAssertEqual(
            try frame(.newPane(session: "work", cwd: nil, command: nil)),
            #"{"op":"structure","verb":{"kind":"newPane","session":"work"}}"#)
    }

    // MARK: Pane-addressed verbs

    func testKillPane() throws {
        // tmuxstructure.go's own example: {"kind":"killPane","pane":5} kills %5.
        XCTAssertEqual(
            try frame(.killPane(pane: 5)),
            #"{"op":"structure","verb":{"kind":"killPane","pane":5}}"#)
    }

    func testSelectPane() throws {
        XCTAssertEqual(
            try frame(.selectPane(pane: 0)),
            #"{"op":"structure","verb":{"kind":"selectPane","pane":0}}"#)
    }

    func testRenamePane() throws {
        XCTAssertEqual(
            try frame(.renamePane(pane: 2, to: "build-pane")),
            #"{"op":"structure","verb":{"kind":"renamePane","pane":2,"to":"build-pane"}}"#)
    }

    func testToggleZoom() throws {
        XCTAssertEqual(
            try frame(.toggleZoom(pane: 1)),
            #"{"op":"structure","verb":{"kind":"toggleZoom","pane":1}}"#)
    }

    func testSwapPane() throws {
        XCTAssertEqual(
            try frame(.swapPane(pane: 4, up: true)),
            #"{"op":"structure","verb":{"kind":"swapPane","pane":4,"up":true}}"#)
        XCTAssertEqual(
            try frame(.swapPane(pane: 4, up: false)),
            #"{"op":"structure","verb":{"kind":"swapPane","pane":4}}"#)
    }

    func testSwapPanes() throws {
        XCTAssertEqual(
            try frame(.swapPanes(a: 0, b: 1)),
            #"{"op":"structure","verb":{"a":0,"b":1,"kind":"swapPanes"}}"#)
    }

    func testDockPane() throws {
        XCTAssertEqual(
            try frame(.dockPane(source: 3, at: 1, horizontal: true, before: false)),
            #"{"op":"structure","verb":{"at":1,"horizontal":true,"kind":"dockPane","source":3}}"#)
        XCTAssertEqual(
            try frame(.dockPane(source: 3, at: 1, horizontal: false, before: true)),
            #"{"op":"structure","verb":{"at":1,"before":true,"kind":"dockPane","source":3}}"#)
    }

    func testMovePane() throws {
        XCTAssertEqual(
            try frame(.movePane(pane: 2, toSession: "other")),
            #"{"op":"structure","verb":{"kind":"movePane","pane":2,"to_session":"other"}}"#)
    }

    func testResizePane() throws {
        XCTAssertEqual(
            try frame(.resizePane(pane: 0, direction: "R", amount: 5)),
            #"{"op":"structure","verb":{"amount":5,"direction":"R","kind":"resizePane","pane":0}}"#)
    }

    // MARK: Session-wide verbs

    func testReorderPanes() throws {
        XCTAssertEqual(
            try frame(.reorderPanes(session: "work", order: [2, 0, 1])),
            #"{"op":"structure","verb":{"kind":"reorderPanes","order":[2,0,1],"session":"work"}}"#)
    }

    func testApplyTiled() throws {
        XCTAssertEqual(
            try frame(.applyTiled(session: "work")),
            #"{"op":"structure","verb":{"kind":"applyTiled","session":"work"}}"#)
    }
}
