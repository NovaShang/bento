import Foundation
import Testing
@testable import SwiftTmux

/// Thread-safe collector for parsed notifications.
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

func makeService() -> (TmuxControlMode, NotificationCollector) {
    let service = TmuxControlMode()
    let collector = NotificationCollector()
    service.onNotification = { collector.collect($0) }
    return (service, collector)
}

@Suite("%output unescaping")
struct OutputUnescapeTests {
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

@Suite("Notification parsing")
struct NotificationTests {
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

    @Test func ignoredNotificationsNoCrash() {
        let (s, _) = makeService()
        s.feedData(Data("%sessions-changed\n".utf8))
        s.feedData(Data("%unlinked-window-add @1\n".utf8))
        s.feedData(Data("%unlinked-window-close @1\n".utf8))
        s.feedData(Data("%window-pane-changed @0 %1\n".utf8))
        s.feedData(Data("%client-session-changed $1 main\n".utf8))
        // Reached here = no crash.
    }

    @Test func dcsStrippedBeforeNotification() {
        let (s, c) = makeService()
        s.feedData(Data("\u{1b}P1000p%session-changed $0 test\n".utf8))
        if case .sessionChanged(_, let name) = c.last {
            #expect(name == "test")
        } else { Issue.record("Expected sessionChanged after DCS") }
    }
}


/// A service whose connection greeting (the unsolicited first %begin/%end
/// block of a -CC attach) has already been consumed — i.e. a live session.
func makeAttachedService() -> (TmuxControlMode, NotificationCollector) {
    let (s, c) = makeService()
    s.feedData(Data("%begin 0 0 0\n%end 0 0 0\n".utf8))
    return (s, c)
}

@Suite("Response queue")
struct ResponseQueueTests {
    @Test func fireAndForgetDoesNotStealContinuation() async {
        let (service, _) = makeAttachedService()
        let sent = SendableBox<[String]>([])
        service.sendToSSH = { cmd in sent.update { $0.append(cmd) } }

        service.sendFireAndForget(.selectPane(id: TmuxPaneID(0)))

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        // Two responses arrive. First is consumed by the fire-and-forget
        // counter; second matches the awaited continuation.
        service.feedData(Data("%begin 1 100 1\n%end 1 100 1\n".utf8))
        service.feedData(Data("%begin 1 101 1\npane data\n%end 1 101 1\n".utf8))

        let response = await task.value
        #expect(response.output == "pane data")
        #expect(!response.isError)
    }

    @Test func errorResponseDetected() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data("%begin 1 100 1\nbad command\n%error 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.isError)
        #expect(response.output == "bad command")
    }

    @Test func multiLineResponse() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data("%begin 1 100 1\nline1\nline2\nline3\n%end 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.output == "line1\nline2\nline3")
    }
}

@Suite("Chunked input")
struct ChunkedInputTests {
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

@Suite("Logging hook")
struct LogHandlerTests {
    @Test func logHandlerReceivesCommands() {
        let service = TmuxControlMode()
        service.sendToSSH = { _ in }
        let captured = SendableBox<[String]>([])
        service.logHandler = { line in captured.update { $0.append(line) } }

        service.sendFireAndForget(.selectPane(id: TmuxPaneID(2)))
        #expect(captured.current.contains { $0.contains("select-pane -t %2") })
    }
}

@Suite("Reconnect state reset")
struct ReconnectResetTests {
    /// `%output` takes the raw fast path in `handleLine` and is immune to a
    /// stuck block — pin that down so the zombie analysis below stays honest.
    @Test func outputBypassesStuckBlock() {
        let (s, c) = makeService()
        s.feedData(Data("%begin 100 5 1\n".utf8))          // truncated block
        s.feedData(Data("%output %0 still-flows\n".utf8))
        #expect(c.outputTexts == ["still-flows"])
    }

    /// The "zombie pane" bug, mechanism 1: a response block truncated by a
    /// connection drop (`%begin` seen, `%end` lost) leaves the parser in
    /// block-collection mode, where every non-`%output` notification of the
    /// NEW connection (layout changes, window/session events) is swallowed as
    /// block content.
    @Test func truncatedBlockSwallowsNotificationsWithoutReset() {
        let (s, c) = makeService()
        s.feedData(Data("%begin 100 5 1\n".utf8))          // response starts…
        // …connection dies; %end never arrives. New connection's events:
        s.feedData(Data("%layout-change @1 dead,80x24,0,0,1\n".utf8))
        #expect(c.notifications.isEmpty)                    // swallowed — the bug
        s.reset()
        s.feedData(Data("%layout-change @1 dead,80x24,0,0,1\n".utf8))
        #expect(c.notifications.count == 1)
    }

    /// The "zombie pane" bug, mechanism 2: continuations queued by the dead
    /// connection consume the new connection's response blocks FIFO, starving
    /// the post-reconnect commands. `refreshPanes` on reattach then never
    /// resolves (or resolves with the wrong block), pane view-models get
    /// rebuilt from garbage while surfaces stay bound to the old instances —
    /// input still works, rendering is dead. With the old un-timeboxed
    /// `send()` this hung the reconnect loop forever.
    @Test func orphanedContinuationsStarveNewSendsWithoutReset() async {
        let (s, _) = makeAttachedService()
        s.sendToSSH = { _ in }
        // Dead connection left two commands in flight (never answered).
        async let orphan1 = s.send(.listPanes(), timeout: .seconds(5))
        async let orphan2 = s.send(.listWindows(), timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        // Reconnect WITHOUT reset. The reattach flow sends list-panes; the
        // new connection delivers its greeting + that one real response.
        // (greetingConsumed is still true from the old connection, so the new
        // greeting is treated as an ordinary response — part of the bug.)
        async let fresh = s.send(.listPanes(), timeout: .milliseconds(300))
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%begin 1 0 0\n%end 1 0 0\n".utf8))                 // new greeting
        s.feedData(Data("%begin 2 1 1\n%0 pane data\n%end 2 1 1\n".utf8))   // real response
        let (o1, o2, freshR) = await (orphan1, orphan2, fresh)
        #expect(o1.output.isEmpty)                          // orphan stole the greeting
        #expect(o2.output == "%0 pane data")                // orphan stole the real response
        #expect(freshR.isError)                             // the live caller starved
    }

    @Test func resetFailsPendingContinuations() async {
        let (s, _) = makeService()
        s.sendToSSH = { _ in }                              // command goes nowhere
        async let response = s.send(.listPanes())
        try? await Task.sleep(for: .milliseconds(50))       // let send() enqueue
        s.reset()
        let r = await response
        #expect(r.isError)
        #expect(r.output == "connection reset")
    }

    /// A partial line left in the byte buffer by the dead connection must not
    /// corrupt the first line of the new connection's stream.
    @Test func resetDropsPartialLineBuffer() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 trunca".utf8))          // no newline — stuck partial
        s.reset()
        s.feedData(Data("%output %1 fresh\n".utf8))
        #expect(c.outputTexts == ["fresh"])
    }

    @Test func responseAfterResetMatchesNewSend() async {
        let (s, _) = makeAttachedService()
        s.sendToSSH = { _ in }
        async let orphan = s.send(.listPanes())             // never answered
        try? await Task.sleep(for: .milliseconds(50))
        s.reset()
        _ = await orphan
        async let fresh = s.send(.listWindows())
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%begin 100 8 0\n%end 100 8 0\n".utf8))         // new connection's greeting
        s.feedData(Data("%begin 200 9 1\nwin-1\n%end 200 9 1\n".utf8))  // real response
        let r = await fresh
        #expect(!r.isError)
        #expect(r.output == "win-1")
    }

    /// THE churn regression: a send queued while the greeting block is still
    /// in flight must not have its continuation stolen by the greeting's
    /// `%end`. (This is what awaitControlMode resolving on `%begin` instead of
    /// block completion caused: every response shifted by one, all commands
    /// timed out, the timeout watchdog forced a reconnect, and the cycle
    /// repeated forever.)
    @Test func greetingBlockDoesNotStealSendQueuedMidBlock() async {
        let (s, _) = makeService()
        s.sendToSSH = { _ in }
        s.feedData(Data("%begin 100 1 0\n".utf8))           // greeting starts
        async let r = s.send(.listPanes(), timeout: .seconds(2))
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%end 100 1 0\n".utf8))             // greeting completes
        s.feedData(Data("%begin 101 2 1\npane\n%end 101 2 1\n".utf8))
        let resp = await r
        #expect(!resp.isError)
        #expect(resp.output == "pane")
    }
}

@Suite("Send timeout")
struct SendTimeoutTests {
    @Test func sendTimesOutInsteadOfHanging() async {
        let (s, _) = makeService()
        s.sendToSSH = { _ in }                              // no response will come
        let r = await s.send(.listPanes(), timeout: .milliseconds(100))
        #expect(r.isError)
        #expect(r.output.contains("timeout"))
    }

    @Test func responseBeforeTimeoutWins() async {
        let (s, _) = makeAttachedService()
        s.sendToSSH = { _ in }
        async let response = s.send(.listPanes(), timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%begin 300 2 1\npane-line\n%end 300 2 1\n".utf8))
        let r = await response
        #expect(!r.isError)
        #expect(r.output == "pane-line")
    }
}

@Suite("Control-mode greeting await")
struct AwaitControlModeTests {
    @Test func resolvesWhenGreetingArrives() async {
        let (s, _) = makeService()
        async let ready = s.awaitControlMode(timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%begin 400 1 0\n%end 400 1 0\n".utf8))
        #expect(await ready)
    }

    @Test func resolvesImmediatelyIfAlreadySeen() async {
        let (s, _) = makeService()
        s.feedData(Data("%begin 400 1 0\n%end 400 1 0\n".utf8))
        #expect(await s.awaitControlMode(timeout: .milliseconds(100)))
    }

    @Test func timesOutWhenNoGreeting() async {
        let (s, _) = makeService()
        let ready = await s.awaitControlMode(timeout: .milliseconds(100))
        #expect(!ready)
    }

    @Test func resetRearmsGreetingDetection() async {
        let (s, _) = makeService()
        s.feedData(Data("%begin 400 1 0\n%end 400 1 0\n".utf8))
        s.reset()
        // After reset the OLD greeting must not satisfy a new wait.
        let ready = await s.awaitControlMode(timeout: .milliseconds(100))
        #expect(!ready)
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
