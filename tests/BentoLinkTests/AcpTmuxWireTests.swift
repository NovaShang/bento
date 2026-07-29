import XCTest

@testable import BentoLink

/// The transport-side halves of the tmux wire: the ensure/resize control
/// shapes (key names asserted literally against acphost/proto.go — a wrong
/// key silently degrades daemon-side), the per-unit stdio path (unit
/// boundaries ARE a tmux client's cursor, so coalescing them corrupts it),
/// and the FIFO structureApplied/Failed ack matching.
final class AcpTmuxWireTests: XCTestCase {
    private final class RecordingLink: AcpByteLink, @unchecked Sendable {
        let incoming: AsyncThrowingStream<Data, Error>
        private let cont: AsyncThrowingStream<Data, Error>.Continuation
        private let lock = NSLock()
        private var _sent: [Data] = []

        var sent: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return _sent
        }

        init() {
            var c: AsyncThrowingStream<Data, Error>.Continuation!
            incoming = AsyncThrowingStream { c = $0 }
            cont = c
        }

        func open() async throws {}
        func send(_ data: Data) async throws { record(data) }
        private func record(_ data: Data) {
            lock.lock()
            _sent.append(data)
            lock.unlock()
        }
        func close() { cont.finish() }
        func feed(_ data: Data) { cont.yield(data) }

        /// Decoded control payloads sent so far (plaintext framing).
        func sentControls() -> [[String: Any]] {
            sent.compactMap { unit in
                guard unit.count > 5, unit[unit.startIndex + 4] == 0x01 else { return nil }
                return (try? JSONSerialization.jsonObject(with: unit.dropFirst(5))) as? [String: Any]
            }
        }
    }

    /// Lock-guarded unit recorder (the handler runs off the receive task).
    private final class UnitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var units: [Data] = []
        func append(_ unit: Data) {
            lock.lock()
            units.append(unit)
            lock.unlock()
        }
        func snapshot() -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return units
        }
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

    private func waitFor(_ label: String, timeout: TimeInterval = 5,
                         _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(label)")
                throw XCTSkip("bailing after failed wait")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Control shapes

    func testEnsureTmuxSpawnShape() async throws {
        let link = RecordingLink()
        let transport = AcpHostTransport(link: link, mode: .plaintext)
        try await transport.connect()

        let ensure = Task { try await transport.ensureTmux(target: "local", sessionName: "work") }
        try await waitFor("spawn frame") { link.sentControls().contains { $0["op"] as? String == "spawn" } }
        let spawn = link.sentControls().first { $0["op"] as? String == "spawn" }!
        XCTAssertEqual(spawn["kind"] as? String, "tmux",
                       "the daemon routes on `kind`; anything else spawns an ACP agent")
        XCTAssertEqual(spawn["target"] as? String, "local")
        XCTAssertEqual(spawn["session_id"] as? String, "work",
                       "for kind=tmux, session_id is the tmux SESSION NAME being ensured")
        XCTAssertNil(spawn["cmd"], "an ensure names no command — it is not a process start")

        link.feed(unit(0x01, #"{"op":"attached","agent_id":"tmux:local","running":true}"#))
        let info = try await ensure.value
        XCTAssertEqual(info.agentID, "tmux:local")
        transport.close()
    }

    func testResizeShapeAndAppliedAck() async throws {
        let link = RecordingLink()
        let transport = AcpHostTransport(link: link, mode: .plaintext)
        try await transport.connect()

        let resize = Task { try await transport.resizeTmuxPane(agentID: "tmux:local:%0", cols: 120, rows: 32) }
        try await waitFor("resize frame") { link.sentControls().contains { $0["op"] as? String == "resize" } }
        let frame = link.sentControls().first { $0["op"] as? String == "resize" }!
        XCTAssertEqual(frame["agent_id"] as? String, "tmux:local:%0")
        XCTAssertEqual(frame["cols"] as? Int, 120)
        XCTAssertEqual(frame["rows"] as? Int, 32)

        link.feed(unit(0x01, #"{"op":"structureApplied","target":"local","rev":9}"#))
        let rev = try await resize.value
        XCTAssertEqual(rev, 9, "the ack rev is the mirror rev that already includes the resize")
        transport.close()
    }

    func testStructureFrameFIFOAndRefusal() async throws {
        let link = RecordingLink()
        let transport = AcpHostTransport(link: link, mode: .plaintext)
        try await transport.connect()

        // Two ops in flight; acks match by arrival order (no correlation id
        // on the wire — that IS the protocol).
        let first = Task { try await transport.sendStructureFrame(Data(#"{"op":"structure","verb":{"kind":"selectPane","pane":1}}"#.utf8)) }
        try await waitFor("first frame") { link.sentControls().count >= 1 }
        let second = Task { try await transport.sendStructureFrame(Data(#"{"op":"structure","verb":{"kind":"killPane","pane":9}}"#.utf8)) }
        try await waitFor("second frame") { link.sentControls().count >= 2 }

        link.feed(unit(0x01, #"{"op":"structureApplied","rev":4}"#))
        link.feed(unit(0x01, #"{"op":"structureFailed","error":"no pane %9 in session"}"#))

        let rev = try await first.value
        XCTAssertEqual(rev, 4)
        do {
            _ = try await second.value
            XCTFail("structureFailed must throw")
        } catch AcpHostError.structureRefused(let message) {
            XCTAssertTrue(message.contains("no pane %9"))
        }
        transport.close()
    }

    // MARK: Per-unit stdio

    func testOnStdioUnitPreservesUnitBoundariesAndCredits() async throws {
        let link = RecordingLink()
        let transport = AcpHostTransport(link: link, mode: .plaintext)

        let box = UnitBox()
        transport.onStdioUnit = { unit in box.append(unit) }
        try await transport.connect()

        // Three units in ONE socket read: the batched (ACP) path would hand
        // these up as one chunk; the tmux path must not — the client cursor
        // counts units.
        var burst = Data()
        burst.append(unit(0x02, "alpha"))
        burst.append(unit(0x02, "beta"))
        burst.append(unit(0x02, "g"))
        link.feed(burst)

        try await waitFor("three units") { box.snapshot().count == 3 }
        XCTAssertEqual(box.snapshot().map { String(decoding: $0, as: UTF8.self) },
                       ["alpha", "beta", "g"])

        // Credit mirrors flushStdio's policy — granted per delivered unit,
        // for exactly the bytes delivered.
        try await waitFor("credits") {
            link.sentControls().filter { $0["op"] as? String == "credit" }.count == 3
        }
        let credits = link.sentControls().filter { $0["op"] as? String == "credit" }
            .compactMap { $0["bytes"] as? Int }
        XCTAssertEqual(credits, [5, 4, 1])
        transport.close()
    }
}
