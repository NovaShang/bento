import XCTest
@testable import BentoTmuxPane

// The keystroke coalescer's contract: the leading byte flushes immediately, a
// burst inside the window coalesces into one trailing flush, and byte ORDER is
// preserved end-to-end. Timing is real (a serial dispatch queue), so waits use
// expectations rather than sleeps.
final class TmuxInputCoalescerTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var flushes: [Data] = []
        func record(_ d: Data) { lock.lock(); flushes.append(d); lock.unlock() }
        var joined: String { lock.lock(); defer { lock.unlock() }
            return flushes.map { String(decoding: $0, as: UTF8.self) }.joined() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return flushes.count }
    }

    func testLeadingEdgeFlushesFirstByteImmediately() {
        let rec = Recorder()
        let c = TmuxInputCoalescer(windowMs: 30) { rec.record($0) }
        c.send(Data("a".utf8))
        // The leading flush is async but immediate; give the serial queue a beat.
        let exp = expectation(description: "leading")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(rec.joined, "a")
    }

    func testBurstCoalescesAndPreservesOrder() {
        let rec = Recorder()
        let c = TmuxInputCoalescer(windowMs: 40) { rec.record($0) }
        // A tight burst: the first opens the window (leading), the rest ride the
        // trailing flush.
        for ch in ["h", "e", "l", "l", "o"] { c.send(Data(ch.utf8)) }
        let exp = expectation(description: "settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(rec.joined, "hello")
        // Coalesced: far fewer flushes than the 5 sends (leading + one trailing).
        XCTAssertLessThanOrEqual(rec.count, 2)
    }
}
