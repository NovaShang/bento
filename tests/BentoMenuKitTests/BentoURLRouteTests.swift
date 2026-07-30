import XCTest
@testable import BentoMenuKit

/// The URL scheme is the launch ABI between a resident menu process and the
/// product apps (docs/menubar-unification.md §4.1). Two properties matter and
/// are asserted here rather than left to a hand-check:
///
///  1. The two things we DO handle round-trip through arbitrary session names
///     (spaces, slashes, unicode) — a workspace called "API refactor" must be
///     openable.
///  2. Everything else is nil. A URL arrives from `open(1)` or another app,
///     i.e. from outside the trust boundary; nil is what makes an unknown or
///     malformed one a no-op instead of a crash or a guess.
final class BentoURLRouteTests: XCTestCase {

    private func route(_ string: String, _ scheme: BentoURLScheme) -> BentoURLRoute? {
        guard let url = URL(string: string) else {
            XCTFail("not a URL at all: \(string)")
            return nil
        }
        return BentoURLRouter.route(url, scheme: scheme)
    }

    // MARK: - open / activate

    func testBareSchemeOpensTheApp() {
        XCTAssertEqual(route("bento-acp://", .acp), .open)
        XCTAssertEqual(route("bento-term://", .term), .open)
    }

    func testExplicitOpenVerb() {
        XCTAssertEqual(route("bento-acp://open", .acp), .open)
        XCTAssertEqual(route("bento-term://open", .term), .open)
    }

    /// RFC 3986 says schemes are case-insensitive, and Launch Services hands
    /// us whatever the caller typed.
    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertEqual(route("BENTO-ACP://open", .acp), .open)
        XCTAssertEqual(route("Bento-Term://Open", .term), .open)
    }

    // MARK: - named session / workspace

    func testWorkspaceNameForTheACPApp() {
        XCTAssertEqual(route("bento-acp://workspace/api", .acp), .openSession(name: "api"))
    }

    func testSessionNameForTheTermApp() {
        XCTAssertEqual(route("bento-term://session/build", .term), .openSession(name: "build"))
    }

    /// Both nouns work for both schemes: a link that says "session" to the ACP
    /// app names the same thing its own menu calls a workspace, and nobody
    /// should have to remember which product uses which word.
    func testBothNounsAreAcceptedByBothSchemes() {
        XCTAssertEqual(route("bento-acp://session/api", .acp), .openSession(name: "api"))
        XCTAssertEqual(route("bento-term://workspace/build", .term), .openSession(name: "build"))
    }

    func testPercentEncodedNameIsDecoded() {
        XCTAssertEqual(
            route("bento-acp://workspace/API%20refactor", .acp),
            .openSession(name: "API refactor")
        )
        XCTAssertEqual(
            route("bento-term://session/%E4%BE%BF%E5%BD%93", .term),
            .openSession(name: "便当")
        )
    }

    /// A name is one path segment. Anything after it is ignored rather than
    /// silently folded into the name — "workspace/a/b" is not a workspace
    /// called "a/b".
    func testOnlyTheFirstSegmentIsTheName() {
        XCTAssertEqual(route("bento-acp://workspace/a/b", .acp), .openSession(name: "a"))
    }

    /// The opaque form (`scheme:path`, no authority) puts the verb in `path`
    /// rather than `host`. Users type both; we accept both.
    func testOpaqueFormWithoutDoubleSlash() {
        XCTAssertEqual(route("bento-acp:workspace/api", .acp), .openSession(name: "api"))
        XCTAssertEqual(route("bento-term:open", .term), .open)
    }

    // MARK: - everything else is a no-op

    func testForeignSchemeIsRejected() {
        XCTAssertNil(route("bento-term://session/build", .acp))
        XCTAssertNil(route("bento-acp://workspace/api", .term))
        XCTAssertNil(route("https://example.com/workspace/api", .acp))
        XCTAssertNil(route("file:///etc/passwd", .acp))
    }

    func testUnknownVerbIsRejected() {
        XCTAssertNil(route("bento-acp://quit", .acp))
        XCTAssertNil(route("bento-acp://kill/api", .acp))
        XCTAssertNil(route("bento-term://exec/rm%20-rf", .term))
    }

    func testMissingOrEmptyNameIsRejected() {
        XCTAssertNil(route("bento-acp://workspace", .acp))
        XCTAssertNil(route("bento-acp://workspace/", .acp))
        XCTAssertNil(route("bento-term://session/%20", .term))
    }

    // MARK: - construction

    func testURLForNameRoundTrips() {
        for scheme in BentoURLScheme.allCases {
            for name in ["api", "API refactor", "便当", "a-b_c.1"] {
                guard let url = BentoURLRouter.url(for: name, scheme: scheme) else {
                    XCTFail("no URL for \(name) / \(scheme)")
                    continue
                }
                XCTAssertEqual(BentoURLRouter.route(url, scheme: scheme), .openSession(name: name))
            }
        }
    }

    func testCanonicalNounPerScheme() {
        XCTAssertEqual(
            BentoURLRouter.url(for: "api", scheme: .acp)?.absoluteString,
            "bento-acp://workspace/api"
        )
        XCTAssertEqual(
            BentoURLRouter.url(for: "build", scheme: .term)?.absoluteString,
            "bento-term://session/build"
        )
    }

    /// The registered scheme strings are a shipped contract — they live in two
    /// Info.plists and in any link a user has saved. Pin them.
    func testSchemeStringsArePinned() {
        XCTAssertEqual(BentoURLScheme.acp.rawValue, "bento-acp")
        XCTAssertEqual(BentoURLScheme.term.rawValue, "bento-term")
    }
}
