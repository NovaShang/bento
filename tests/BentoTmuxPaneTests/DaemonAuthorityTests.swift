import XCTest
import BentoWorkbench
@testable import BentoTmuxPane

/// DaemonAuthority's two halves: verbs go out through the encoding seam
/// (never a local tree mutation), snapshots come in through the rev-guarded
/// projection.
@MainActor
final class DaemonAuthorityTests: XCTestCase {
    /// Records what it was asked to encode; the wire shape itself is
    /// stage-2 (it lands with the daemon's `structure` op).
    private final class RecordingEncoding: StructureVerbEncoding, @unchecked Sendable {
        var verbs: [StructureVerb] = []
        var error: Error?
        func encodeStructureFrame(_ verb: StructureVerb) throws -> Data {
            if let error { throw error }
            verbs.append(verb)
            return Data("frame#\(verbs.count)".utf8)
        }
    }

    func testApplyEncodesAndSends() {
        let encoding = RecordingEncoding()
        var frames: [Data] = []
        let authority = DaemonAuthority(encoding: encoding) { frames.append($0) }

        authority.apply(.splitPane(session: "bento", target: 1, horizontal: true,
                                   cwd: nil, command: nil))
        authority.apply(.killPane(pane: 2))

        XCTAssertEqual(encoding.verbs.count, 2)
        guard case .splitPane(let session, let target, let horizontal, _, _) = encoding.verbs[0]
        else { return XCTFail("verb not passed through") }
        XCTAssertEqual(session, "bento")
        XCTAssertEqual(target, 1)
        XCTAssertTrue(horizontal)
        XCTAssertEqual(frames, [Data("frame#1".utf8), Data("frame#2".utf8)])
    }

    func testEncodeFailureSendsNothing() {
        let encoding = RecordingEncoding()
        encoding.error = NSError(domain: "test", code: 1)
        var frames: [Data] = []
        let authority = DaemonAuthority(encoding: encoding) { frames.append($0) }

        authority.apply(.selectPane(pane: 1))
        XCTAssertTrue(frames.isEmpty)
    }

    func testIngestProjectsAndGuardsRev() {
        let authority = DaemonAuthority(encoding: RecordingEncoding(),
                                        entryID: 9) { _ in }
        var projected: [(name: String, rev: UInt64)] = []
        authority.onProjection = { entry, state in
            projected.append((entry.name, state.rev))
        }

        XCTAssertTrue(authority.ingest(
            stateValue: TmuxStructureProjectionTests.capturedSnapshot))
        XCTAssertEqual(authority.lastState?.rev, 7)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].name, "bento")

        // Same rev again (a reconnect re-pull) must not re-project…
        XCTAssertFalse(authority.ingest(
            stateValue: TmuxStructureProjectionTests.capturedSnapshot))
        XCTAssertEqual(projected.count, 1)

        // …and a NEWER rev must.
        var newer = TmuxStructureDecoding.decode(
            TmuxStructureProjectionTests.capturedSnapshot)!
        newer.rev = 8
        newer.session = "renamed"
        let data = try! JSONEncoder().encode(newer)
        XCTAssertTrue(authority.ingest(stateValue: data))
        XCTAssertEqual(projected.count, 2)
        XCTAssertEqual(projected[1].name, "renamed")
        XCTAssertEqual(projected[1].rev, 8)
    }

    func testIngestIgnoresGarbage() {
        let authority = DaemonAuthority(encoding: RecordingEncoding()) { _ in }
        XCTAssertFalse(authority.ingest(stateValue: Data("junk".utf8)))
        XCTAssertNil(authority.lastState)
    }
}
