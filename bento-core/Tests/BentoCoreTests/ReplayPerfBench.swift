import ACPKit
import XCTest

@testable import BentoCore

/// Temp benchmark: feeds a captured daemon scrollback replay through the
/// client pipeline to see where cold-start time goes. Skipped unless
/// BENTO_REPLAY_CAPTURE points at an ndjson capture.
final class ReplayPerfBench: XCTestCase {
    private func capture() throws -> [Data] {
        guard let path = ProcessInfo.processInfo.environment["BENTO_REPLAY_CAPTURE"] else {
            throw XCTSkip("no capture")
        }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        var lines: [Data] = []
        var start = raw.startIndex
        while let nl = raw[start...].firstIndex(of: 0x0A) {
            if nl > start { lines.append(Data(raw[start..<nl])) }
            start = raw.index(after: nl)
        }
        if start < raw.endIndex { lines.append(Data(raw[start...])) }
        return lines
    }

    struct Header: Decodable { let method: String?; let id: Int? }
    struct Envelope: Decodable { let params: SessionNotification }

    @MainActor
    func testReplayCost() throws {
        let lines = try capture()
        let bytes = lines.reduce(0) { $0 + $1.count }
        print("lines=\(lines.count) bytes=\(bytes)")

        let dec = JSONDecoder()

        var t = Date()
        var headers = 0
        for line in lines where (try? dec.decode(Header.self, from: line)) != nil { headers += 1 }
        let headerCost = -t.timeIntervalSinceNow
        print(String(format: "header decode: %.3fs (%d)", headerCost, headers))

        t = Date()
        var notes: [SessionNotification] = []
        for line in lines {
            if let e = try? dec.decode(Envelope.self, from: line) { notes.append(e.params) }
        }
        let envCost = -t.timeIntervalSinceNow
        print(String(format: "envelope decode: %.3fs (%d notes)", envCost, notes.count))

        let vm = AgentSessionViewModel(preset: .claude, cwd: "/tmp")
        t = Date()
        for n in notes { vm.handle(n) }
        let applyCost = -t.timeIntervalSinceNow
        print(String(format: "apply: %.3fs -> %d items", applyCost, vm.items.count))
        print(String(format: "TOTAL %.3fs for %.1f MB", headerCost + envCost + applyCost, Double(bytes) / 1e6))
    }
}
