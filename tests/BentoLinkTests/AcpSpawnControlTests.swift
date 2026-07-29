import XCTest

@testable import BentoLink

/// The spawn control's wire shape. This is the one place where a mistake is
/// SILENT on both sides: if the conversation field doesn't serialize under
/// the exact key the daemon reads, the daemon simply spawns unconditionally
/// — the previous behavior — and neither end logs anything. So the key names
/// are asserted literally, against desktop/internal/acphost/proto.go.
final class AcpSpawnControlTests: XCTestCase {
    private func encoded(_ control: AcpControl) throws -> [String: Any] {
        let data = try JSONEncoder().encode(control)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testResumingSpawnCarriesConversationAndCursor() throws {
        let json = try encoded(AcpControl(
            op: "spawn", cmd: "claude-agent-acp", args: [], cwd: "/p", env: [:],
            haveSeq: 7, catchup: true, sessionId: "sess-abc"))

        XCTAssertEqual(json["op"] as? String, "spawn")
        XCTAssertEqual(json["session_id"] as? String, "sess-abc",
                       "the daemon reads `session_id`; any other key means spawn-or-adopt silently degrades")
        XCTAssertEqual(json["have_seq"] as? UInt64, 7)
        XCTAssertEqual(json["catchup"] as? Bool, true)
    }

    /// A brand-new conversation must NOT claim one: omitting the field is
    /// what tells the daemon "always a fresh process".
    func testFreshSpawnOmitsTheConversation() throws {
        let json = try encoded(AcpControl(
            op: "spawn", cmd: "opencode", args: ["acp"], cwd: "/p", env: [:]))

        XCTAssertNil(json["session_id"])
        XCTAssertNil(json["catchup"])
    }

    /// The daemon's `attached` reply decodes into the catch-up fields the
    /// bootstrap path branches on.
    func testAttachedReplyDecodesCatchupBounds() throws {
        let wire = Data("""
        {"op":"attached","agent_id":"a1","running":true,"acp_session_id":"sess-abc",\
        "head_seq":42,"start_seq":8,"replay":true}
        """.utf8)
        let control = try JSONDecoder().decode(AcpControl.self, from: wire)

        XCTAssertEqual(control.agentId, "a1")
        XCTAssertEqual(control.acpSessionId, "sess-abc")
        XCTAssertEqual(control.headSeq, 42)
        XCTAssertEqual(control.startSeq, 8)
        XCTAssertEqual(control.replay, true)
    }
}
