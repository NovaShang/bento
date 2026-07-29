import XCTest

@testable import BentoLink

/// The three lines between "the daemon broadcast it" and "the view model
/// reacted": a control op arriving on the wire has to become a host event.
/// Both ends of that seam are covered elsewhere — the daemon's broadcast in
/// Go, the view model's reaction in BentoCore — and only the middle could
/// silently do nothing, because a control op the transport doesn't recognize
/// is dropped without a word.
final class AcpHostEventRoutingTests: XCTestCase {
    /// Feeds raw daemon→client bytes into a transport with no socket behind it.
    private final class FakeLink: AcpByteLink, @unchecked Sendable {
        let incoming: AsyncThrowingStream<Data, Error>
        private let cont: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            incoming = AsyncThrowingStream { captured = $0 }
            cont = captured
        }

        func open() async throws {}
        func send(_ data: Data) async throws {}
        func close() { cont.finish() }

        /// Frame a control op the way the daemon does: length-prefixed unit,
        /// type byte 0x01, JSON body.
        func pushControl(_ json: String) {
            let body = Data([AcpHostProtocol.unitTypeControl]) + Data(json.utf8)
            cont.yield(acpPrefixUnit(body))
        }
    }

    private func firstEvent(fromControl json: String) async throws -> AcpHostEvent? {
        let link = FakeLink()
        let transport = AcpHostTransport(link: link, mode: .plaintext)
        let received = expectation(description: "event")
        let box = EventBox()
        transport.onEvent = { event in
            if box.store(event) { received.fulfill() }
        }
        try await transport.connect()
        link.pushControl(json)
        await fulfillment(of: [received], timeout: 3)
        transport.close()
        return box.value
    }

    /// `onEvent` fires off the receive loop, so the capture needs a lock.
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var event: AcpHostEvent?
        var value: AcpHostEvent? { lock.lock(); defer { lock.unlock() }; return event }

        /// True on the first event only, so the expectation fulfills once.
        func store(_ e: AcpHostEvent) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard event == nil else { return false }
            event = e
            return true
        }
    }

    func testTurnStartedBecomesAHostEvent() async throws {
        let event = try await firstEvent(fromControl: #"{"op":"turnStarted","agent_id":"a1"}"#)
        guard case .turnStartedElsewhere = event else {
            return XCTFail("turnStarted did not reach the client as an event: \(String(describing: event))")
        }
    }

    func testRequestAnsweredCarriesTheRequestID() async throws {
        let event = try await firstEvent(
            fromControl: #"{"op":"requestAnswered","agent_id":"a1","request_id":"7"}"#)
        guard case .agentRequestAnswered(let id) = event else {
            return XCTFail("requestAnswered did not reach the client: \(String(describing: event))")
        }
        XCTAssertEqual(id, "7")
    }

    /// The half that already worked, asserted alongside its new twin so the
    /// pair can't drift apart.
    func testTurnDoneStillBecomesAHostEvent() async throws {
        let event = try await firstEvent(
            fromControl: #"{"op":"turnDone","agent_id":"a1","line":"end_turn"}"#)
        guard case .turnFinishedWhileDetached(let reason) = event else {
            return XCTFail("turnDone regressed: \(String(describing: event))")
        }
        XCTAssertEqual(reason, "end_turn")
    }
}
