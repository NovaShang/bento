import XCTest
import CoreGraphics
@testable import BentoTerminalCore

/// Deterministic tests for the shared voice logic (the compass that decides what
/// happens to a transcript, the language mapping, and that the engine + Mac
/// objects construct). The live ASR loop itself needs a real mic and is verified
/// by hand.
final class VoiceTests: XCTestCase {

    func testCompassDeadZoneAndAxes() {
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 0, height: 0)), .none)
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 30, height: 30)), .none,
                       "within the 40pt dead zone")
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 0, height: -60)), .up,
                       "y-up (negative) drag = send")
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 0, height: 60)), .down,
                       "y-down drag = cancel")
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 60, height: 0)), .right)
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: -60, height: 0)), .left)
        // Axis dominance: the larger component wins.
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 60, height: 20)), .right)
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 20, height: -60)), .up)
    }

    func testCompassThreshold() {
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 50, height: 0), threshold: 100), .none)
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 50, height: 0), threshold: 30), .right)
    }

    func testLanguageHint() {
        XCTAssertEqual(openAILanguageHint(for: "zh-Hans"), "zh")
        XCTAssertEqual(openAILanguageHint(for: "en-US"), "en")
        XCTAssertEqual(openAILanguageHint(for: "ja-JP"), "ja")
        XCTAssertEqual(openAILanguageHint(for: "auto"), "")
    }

    func testResultRoundTrips() {
        let r = VoiceInputResult(text: "ls -la", direction: .right)
        XCTAssertEqual(r.text, "ls -la")
        XCTAssertEqual(r.direction, .right)
    }

    @MainActor
    func testVoiceObjectsConstruct() {
        _ = VoiceSession()
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let controller = MacVoiceController()
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(controller.activeDirection, .none)
        let overlay = MacVoiceOverlay(frame: .init(x: 0, y: 0, width: 300, height: 320))
        overlay.transcript = "hello"
        overlay.direction = .up
        overlay.layout()   // exercises the compass layout math
        #endif
    }
}
