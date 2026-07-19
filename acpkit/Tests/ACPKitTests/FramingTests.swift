import XCTest

@testable import ACPKit

final class FramingTests: XCTestCase {
    private func lines(_ chunks: [String]) -> [String] {
        var buffer = NDJSONLineBuffer()
        var out: [String] = []
        for chunk in chunks {
            for line in buffer.append(Data(chunk.utf8)) {
                out.append(String(data: line, encoding: .utf8)!)
            }
        }
        return out
    }

    func testSingleLine() {
        XCTAssertEqual(lines(["{\"a\":1}\n"]), ["{\"a\":1}"])
    }

    func testPartialLineAcrossChunks() {
        XCTAssertEqual(lines(["{\"a\"", ":1}", "\n{\"b\":2}\n"]), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testMultipleLinesInOneChunk() {
        XCTAssertEqual(lines(["{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"]), ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
    }

    func testCRLFAndBlankLinesTolerated() {
        XCTAssertEqual(lines(["{\"a\":1}\r\n\n\r\n{\"b\":2}\n"]), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testTrailingPartialHeldBack() {
        var buffer = NDJSONLineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"partial".utf8)).count, 1)
        XCTAssertEqual(buffer.append(Data("\":2}\n".utf8)).count, 1)
    }

    func testUTF8MultibyteSplitAcrossChunks() {
        // "你好" split mid-codepoint must reassemble correctly.
        let full = Data("{\"t\":\"你好\"}\n".utf8)
        let cut = full.count - 6
        let result = lines([
            String(decoding: full.prefix(cut), as: UTF8.self),
        ])
        XCTAssertTrue(result.isEmpty)
        var buffer = NDJSONLineBuffer()
        _ = buffer.append(full.prefix(cut))
        let final = buffer.append(full.suffix(from: full.index(full.startIndex, offsetBy: cut)))
        XCTAssertEqual(String(data: final[0], encoding: .utf8), "{\"t\":\"你好\"}")
    }
}
