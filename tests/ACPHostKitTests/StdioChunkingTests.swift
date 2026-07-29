import XCTest

@testable import ACPHostKit

/// The daemon writes ONE unit per JSON-RPC line. Yielding per unit made every
/// line its own read upstream — its own decode hop, its own UI invalidation —
/// which is what made a cold catch-up replay (thousands of lines arriving in a
/// handful of socket reads) crawl. Units that arrive together must be handed
/// up together.
final class StdioChunkingTests: XCTestCase {
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

    private func unit(_ type: UInt8, _ payload: String) -> Data {
        var body = Data([type])
        body.append(Data(payload.utf8))
        var len = UInt32(body.count).bigEndian
        var out = Data()
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    func testStdioUnitsInOneReadArriveAsOneChunk() async throws {
        let link = FakeLink()
        let transport = AcpHostTransport(link: link, mode: .plaintext)
        try await transport.connect()

        var burst = Data()
        for i in 1...40 { burst.append(unit(0x02, "line \(i)\n")) }
        link.feed(burst)

        var chunks: [Data] = []
        for try await chunk in transport.incoming {
            chunks.append(chunk)
            break
        }
        XCTAssertEqual(chunks.count, 1)
        let text = String(data: chunks[0], encoding: .utf8) ?? ""
        XCTAssertEqual(text.split(separator: "\n").count, 40, "all 40 lines in one chunk")
        transport.close()
    }

    /// A control unit still splits the stream: `turnDone`/`exit` must not
    /// overtake the stdio that preceded them.
    func testControlUnitSplitsTheStdioChunk() async throws {
        let link = FakeLink()
        let transport = AcpHostTransport(link: link, mode: .plaintext)
        try await transport.connect()

        var burst = Data()
        burst.append(unit(0x02, "before\n"))
        burst.append(unit(0x01, #"{"op":"turnDone","line":"end_turn"}"#))
        burst.append(unit(0x02, "after\n"))
        link.feed(burst)

        var chunks: [String] = []
        for try await chunk in transport.incoming {
            chunks.append(String(data: chunk, encoding: .utf8) ?? "")
            if chunks.count == 2 { break }
        }
        XCTAssertEqual(chunks, ["before\n", "after\n"], "the control unit split the batch")
        transport.close()
    }
}
