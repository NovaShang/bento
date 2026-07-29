import XCTest

@testable import ACPHostKit

/// The daemon starts delivering the moment it answers `attach`, but a caller
/// can only bind `onEvent` once it holds the transport. Events that land in
/// that window must survive it — `turnDone` in particular is sent exactly
/// once and has no other path to the client, so dropping it strands the pane
/// on a turn that already ended.
final class AcpHostEventBufferTests: XCTestCase {
    /// Minimal in-memory link: `feed` pushes bytes as if the daemon sent them.
    private final class FakeLink: AcpByteLink, @unchecked Sendable {
        let incoming: AsyncThrowingStream<Data, Error>
        private let cont: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var c: AsyncThrowingStream<Data, Error>.Continuation!
            incoming = AsyncThrowingStream { c = $0 }
            cont = c
        }

        func open() async throws {}
        func send(_ data: Data) async throws {}
        func close() { cont.finish() }
        func feed(_ data: Data) { cont.yield(data) }
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AcpHostEvent] = []

        func record(_ event: AcpHostEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        var stopReasons: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events.compactMap {
                if case .turnFinishedWhileDetached(let reason) = $0 { return reason }
                return nil
            }
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return events.count
        }
    }

    private func controlUnit(_ json: String) -> Data {
        acpPrefixUnit(Data([AcpHostProtocol.unitTypeControl]) + Data(json.utf8))
    }

    /// Let the receive loop drain what was fed.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func connectedTransport() async throws -> (AcpHostTransport, FakeLink) {
        let link = FakeLink()
        let transport = AcpHostTransport(link: link, mode: .plaintext)
        try await transport.connect()
        return (transport, link)
    }

    func testTurnDoneBeforeHandlerBoundIsDelivered() async throws {
        let (transport, link) = try await connectedTransport()
        defer { link.close() }

        link.feed(controlUnit(#"{"op":"turnDone","agent_id":"a1","line":"end_turn"}"#))
        try await settle()

        let box = EventBox()
        transport.onEvent = { box.record($0) }
        try await settle()

        XCTAssertEqual(box.stopReasons, ["end_turn"])
    }

    /// Once a handler exists, events flow straight through — the buffer must
    /// not re-deliver or reorder anything.
    func testEventsAfterBindingArriveOnceInOrder() async throws {
        let (transport, link) = try await connectedTransport()
        defer { link.close() }

        let box = EventBox()
        transport.onEvent = { box.record($0) }
        link.feed(controlUnit(#"{"op":"turnDone","agent_id":"a1","line":"end_turn"}"#))
        link.feed(controlUnit(#"{"op":"turnDone","agent_id":"a1","line":"cancelled"}"#))
        try await settle()

        XCTAssertEqual(box.stopReasons, ["end_turn", "cancelled"])
    }

    /// A stderr flood must not push the turn end out of a full buffer.
    func testChatterIsEvictedBeforeLifecycleEvents() async throws {
        let (transport, link) = try await connectedTransport()
        defer { link.close() }

        link.feed(controlUnit(#"{"op":"turnDone","agent_id":"a1","line":"end_turn"}"#))
        for i in 0..<(AcpHostTransport.maxPendingEvents * 2) {
            link.feed(controlUnit(#"{"op":"stderr","line":"noise \#(i)"}"#))
        }
        try await settle()

        let box = EventBox()
        transport.onEvent = { box.record($0) }
        try await settle()

        XCTAssertEqual(box.stopReasons, ["end_turn"], "turn end evicted by stderr chatter")
        XCTAssertLessThanOrEqual(box.count, AcpHostTransport.maxPendingEvents)
    }
}
