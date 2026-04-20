import Foundation
import Testing
@testable import SpeakTerm

/// Thread-safe collector for test notifications
final class NotificationCollector: @unchecked Sendable {
    private var _notifications: [TmuxNotification] = []
    private let lock = NSLock()

    var notifications: [TmuxNotification] {
        lock.lock(); defer { lock.unlock() }
        return _notifications
    }

    var lastOutput: Data? {
        lock.lock(); defer { lock.unlock() }
        for n in _notifications.reversed() {
            if case .output(_, let data) = n { return data }
        }
        return nil
    }

    var outputPaneIDs: [TmuxPaneID] {
        lock.lock(); defer { lock.unlock() }
        return _notifications.compactMap { if case .output(let p, _) = $0 { return p } else { return nil } }
    }

    var last: TmuxNotification? {
        lock.lock(); defer { lock.unlock() }
        return _notifications.last
    }

    func collect(_ n: TmuxNotification) {
        lock.lock(); defer { lock.unlock() }
        _notifications.append(n)
    }

    var outputTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _notifications.compactMap {
            if case .output(_, let data) = $0 { return String(data: data, encoding: .utf8) }
            return nil
        }
    }
}

func makeService() -> (TmuxControlModeService, NotificationCollector) {
    let service = TmuxControlModeService()
    let collector = NotificationCollector()
    service.onNotification = { collector.collect($0) }
    return (service, collector)
}

// MARK: - Output Unescaping Tests

@Suite("Tmux Output Unescaping")
struct TmuxUnescapeTests {

    @Test func plainASCII() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 hello world\n".utf8))
        #expect(c.lastOutput == "hello world".data(using: .utf8))
    }

    @Test func octalNewline() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 line1\012line2"#.appending("\n").utf8))
        #expect(c.lastOutput == "line1\nline2".data(using: .utf8))
    }

    @Test func octalTab() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 col1\011col2"#.appending("\n").utf8))
        #expect(c.lastOutput == "col1\tcol2".data(using: .utf8))
    }

    @Test func octalCarriageReturn() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 text\015"#.appending("\n").utf8))
        #expect(c.lastOutput == "text\r".data(using: .utf8))
    }

    @Test func octalBackslash() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 path\134file"#.appending("\n").utf8))
        #expect(c.lastOutput == "path\\file".data(using: .utf8))
    }

    @Test func octalEscape() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 \033[31mred\033[0m"#.appending("\n").utf8))
        #expect(c.lastOutput == "\u{1b}[31mred\u{1b}[0m".data(using: .utf8))
    }

    @Test func multipleOctalsInRow() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 \033[2J\033[H"#.appending("\n").utf8))
        #expect(c.lastOutput == "\u{1b}[2J\u{1b}[H".data(using: .utf8))
    }

    @Test func utf8BoxDrawingPreserved() {
        let (s, c) = makeService()
        var rawLine = Data("%output %0 ".utf8)
        rawLine.append(contentsOf: [0xE2, 0x95, 0xAD]) // ╭
        rawLine.append(contentsOf: [0xE2, 0x94, 0x80]) // ─
        rawLine.append(contentsOf: [0xE2, 0x95, 0xAE]) // ╮
        rawLine.append(0x0A)
        s.feedData(rawLine)
        #expect(c.lastOutput == Data([0xE2, 0x95, 0xAD, 0xE2, 0x94, 0x80, 0xE2, 0x95, 0xAE]))
    }

    @Test func utf8ChinesePreserved() {
        let (s, c) = makeService()
        var rawLine = Data("%output %0 ".utf8)
        rawLine.append(contentsOf: [0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD]) // 你好
        rawLine.append(0x0A)
        s.feedData(rawLine)
        #expect(c.lastOutput == "你好".data(using: .utf8))
    }

    @Test func emptyOutput() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 \n".utf8))
        #expect(c.lastOutput == Data())
    }

    @Test func paneIDRouting() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 a\n%output %5 b\n%output %12 c\n".utf8))
        #expect(c.outputPaneIDs == [TmuxPaneID(0), TmuxPaneID(5), TmuxPaneID(12)])
    }
}

// MARK: - Notification Parsing Tests

@Suite("Tmux Notification Parsing")
struct TmuxNotificationTests {

    @Test func sessionChanged() {
        let (s, c) = makeService()
        s.feedData(Data("%session-changed $0 mysession\n".utf8))
        if case .sessionChanged(let id, let name) = c.last {
            #expect(id == TmuxSessionID(0))
            #expect(name == "mysession")
        } else { Issue.record("Expected sessionChanged") }
    }

    @Test func layoutChange() {
        let (s, c) = makeService()
        s.feedData(Data("%layout-change @0 b25d,80x24,0,0,0\n".utf8))
        if case .layoutChange(let id, let layout) = c.last {
            #expect(id == TmuxWindowID(0))
            #expect(layout == "b25d,80x24,0,0,0")
        } else { Issue.record("Expected layoutChange") }
    }

    @Test func layoutChangeExtraFields() {
        let (s, c) = makeService()
        s.feedData(Data("%layout-change @0 b99d,54x54,0,0,0 b99d,54x54,0,0,0 *\n".utf8))
        if case .layoutChange(let id, let layout) = c.last {
            #expect(id == TmuxWindowID(0))
            #expect(layout == "b99d,54x54,0,0,0")
        } else { Issue.record("Expected layoutChange") }
    }

    @Test func windowAdd() {
        let (s, c) = makeService()
        s.feedData(Data("%window-add @5\n".utf8))
        if case .windowAdd(let id) = c.last {
            #expect(id == TmuxWindowID(5))
        } else { Issue.record("Expected windowAdd") }
    }

    @Test func windowClose() {
        let (s, c) = makeService()
        s.feedData(Data("%window-close @3\n".utf8))
        if case .windowClose(let id) = c.last {
            #expect(id == TmuxWindowID(3))
        } else { Issue.record("Expected windowClose") }
    }

    @Test func exitNoReason() {
        let (s, c) = makeService()
        s.feedData(Data("%exit\n".utf8))
        if case .exit(let reason) = c.last {
            #expect(reason == nil)
        } else { Issue.record("Expected exit") }
    }

    @Test func exitWithReason() {
        let (s, c) = makeService()
        s.feedData(Data("%exit client detached\n".utf8))
        if case .exit(let reason) = c.last {
            #expect(reason == "client detached")
        } else { Issue.record("Expected exit with reason") }
    }

    @Test func ignoredNotificationsNoError() {
        let (s, _) = makeService()
        s.feedData(Data("%sessions-changed\n".utf8))
        s.feedData(Data("%unlinked-window-add @1\n".utf8))
        s.feedData(Data("%unlinked-window-close @1\n".utf8))
        s.feedData(Data("%window-pane-changed @0 %1\n".utf8))
        s.feedData(Data("%client-session-changed $1 main\n".utf8))
        // No crash = pass
    }

    @Test func dcsStrippedFromLine() {
        let (s, c) = makeService()
        s.feedData(Data("\u{1b}P1000p%session-changed $0 test\n".utf8))
        if case .sessionChanged(_, let name) = c.last {
            #expect(name == "test")
        } else { Issue.record("Expected sessionChanged after DCS") }
    }
}

// MARK: - Response Queue Tests

@Suite("Tmux Response Queue")
struct TmuxResponseQueueTests {

    @Test func fireAndForgetDoesNotStealContinuation() async {
        let service = TmuxControlModeService()
        let sent = SendableBox<[String]>([])
        service.sendToSSH = { cmd in sent.update { $0.append(cmd) } }

        // Fire-and-forget: increments pendingFireAndForget
        service.sendFireAndForget(.selectPane(id: TmuxPaneID(0)))

        // send() that expects a response
        let task = Task {
            await service.send(.listPanes())
        }
        try? await Task.sleep(for: .milliseconds(50))

        // Two responses: 1st consumed by fire-and-forget, 2nd matched to send()
        service.feedData(Data("%begin 1 100 1\n%end 1 100 1\n".utf8))
        service.feedData(Data("%begin 1 101 1\npane data\n%end 1 101 1\n".utf8))

        let response = await task.value
        #expect(response.output == "pane data")
        #expect(!response.isError)
    }

    @Test func errorResponseDetected() async {
        let service = TmuxControlModeService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data("%begin 1 100 1\nbad command\n%error 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.isError)
        #expect(response.output == "bad command")
    }

    @Test func multiLineResponse() async {
        let service = TmuxControlModeService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data("%begin 1 100 1\nline1\nline2\nline3\n%end 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.output == "line1\nline2\nline3")
    }
}

// MARK: - Chunked Data Tests

@Suite("Tmux Chunked Input")
struct TmuxChunkedInputTests {

    @Test func splitAcrossChunks() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 hel".utf8))
        #expect(c.lastOutput == nil) // no newline yet
        s.feedData(Data("lo\n".utf8))
        #expect(c.lastOutput == "hello".data(using: .utf8))
    }

    @Test func multipleLineInOneChunk() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 first\n%output %0 second\n%output %1 third\n".utf8))
        #expect(c.outputTexts == ["first", "second", "third"])
    }

    @Test func crlfHandled() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 test\r\n".utf8))
        #expect(c.lastOutput == "test".data(using: .utf8))
    }
}

// MARK: - Helpers

final class SendableBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
    var current: T { lock.lock(); defer { lock.unlock() }; return value }
}
