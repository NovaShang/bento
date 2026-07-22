#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import ACPKit
import AppKit
import SwiftUI
import XCTest

@testable import BentoCore

/// Windowed regression tests for transcript scroll ownership
/// (`AgentChatSurface`'s bottom anchor). The contract under test:
/// - a pinned reader stays on the REAL bottom through composer growth
///   (not parked past the content in blank space),
/// - an overshoot past the content (what SwiftUI's lazy-estimate scrollTo
///   does on session restore) walks back on the next content growth,
/// - the keep-bottom machinery never touches the composer editor's own
///   internal scrolling (it is an NSScrollView too, and used to win the
///   "first scroll view found" resolution).
@MainActor
final class TranscriptScrollAnchorTests: XCTestCase {

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func note(_ update: String) -> SessionNotification {
        let json = #"{"sessionId":"ses_test","update":\#(update)}"#
        return try! JSONDecoder().decode(SessionNotification.self, from: Data(json.utf8))
    }

    private func say(_ vm: AgentSessionViewModel, _ role: String, _ text: String) {
        vm.handle(note(#"{"sessionUpdate":"\#(role)","content":{"type":"text","text":"\#(text)"}}"#))
    }

    /// Alternating user/agent prose creates one transcript item per row
    /// (same-role chunks would coalesce into a single message).
    private func fillTranscript(_ vm: AgentSessionViewModel, rows: Int) {
        for i in 0..<rows {
            let role = i.isMultiple(of: 2) ? "user_message_chunk" : "agent_message_chunk"
            say(vm, role, "row \(i): enough prose to occupy a transcript line and wrap once in a five-hundred-point pane, keeping the layout honest.")
        }
    }

    /// A surface in a real window, sized like a modest pane, laid out.
    private func makeSurface(rows: Int) -> (AgentSessionViewModel, AgentChatSurface, NSWindow) {
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        fillTranscript(vm, rows: rows)
        let surface = AgentChatSurface(session: vm)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.orderFront(nil)
        // Long enough for the hosting subtree to materialize AND for the
        // surface's own deferred scroll resolution to attach the anchor.
        spin(0.6)
        return (vm, surface, window)
    }

    private func teardown(_ surface: AgentChatSurface, _ window: NSWindow) {
        surface.teardown()
        window.orderOut(nil)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { result.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return result
    }

    private func transcriptScroll(in surface: AgentChatSurface) -> NSScrollView? {
        scrollViews(in: surface).filter { !($0.documentView is NSTextView) }
            .max { $0.frame.height < $1.frame.height }
    }

    private func composerScroll(in surface: AgentChatSurface) -> NSScrollView? {
        scrollViews(in: surface).first { $0.documentView is NSTextView }
    }

    private func assertAtBottom(
        _ scroll: NSScrollView, _ context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let gap = bottomGap(scroll)
        XCTAssertGreaterThanOrEqual(
            gap, -1, "viewport parked PAST the content (blank area) \(context)",
            file: file, line: line)
        XCTAssertLessThanOrEqual(
            gap, 10, "viewport drifted off the tail (gap \(gap)) \(context)",
            file: file, line: line)
    }

    /// Distance from the tail. ~0 = pinned; negative = parked PAST the content
    /// (blank space). Inset-aware: the floating composer is a bottom content
    /// inset, so at the tail the document bottom sits `insets.bottom` above the
    /// clip's bottom edge (clearing the bar), which this adds back in.
    private func bottomGap(_ scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView
        let docH = clip.documentView?.frame.height ?? 0
        return docH - clip.bounds.height + scroll.contentInsets.bottom - clip.bounds.origin.y
    }

    func testComposerGrowthKeepsPinnedTranscriptOnRealBottom() throws {
        let (vm, surface, window) = makeSurface(rows: 40)
        defer { teardown(surface, window) }
        guard let transcript = transcriptScroll(in: surface),
            let doc = transcript.documentView,
            doc.frame.height > transcript.contentView.bounds.height + 100
        else { throw XCTSkip("hosted transcript did not lay out in this environment") }

        // Starts pinned at the bottom (defaultScrollAnchor). SwiftUI's own
        // resting point sits a few points shy of docH - visH, so "at the
        // tail" is a small positive gap; NEGATIVE means parked past the
        // content in blank space — the actual bug class under test.
        assertAtBottom(transcript, "after initial layout")

        // Grow the composer several lines; the transcript viewport shrinks
        // and must stay glued to the REAL bottom, not slide into blank.
        vm.composerDraft = Array(repeating: "line", count: 12).joined(separator: "\n")
        spin(0.5)

        assertAtBottom(transcript, "after composer growth")
    }

    /// SEND from a multi-line composer: the draft clears (the field SHRINKS
    /// several lines in one turn) at the same time the sent user row appends,
    /// and NOTHING streams after (the agent hasn't answered yet). The pinned
    /// viewport must land on the new tail with rows materialized — not stranded
    /// in the blank band the shrink+append churn can open below the content.
    func testSendFromMultilineComposerKeepsBottom() throws {
        let (vm, surface, window) = makeSurface(rows: 40)
        defer { teardown(surface, window) }
        guard let transcript = transcriptScroll(in: surface),
            let doc = transcript.documentView,
            doc.frame.height > transcript.contentView.bounds.height + 100
        else { throw XCTSkip("hosted transcript did not lay out in this environment") }
        assertAtBottom(transcript, "after initial layout")

        // Grow the composer to several lines (a real multi-line draft).
        vm.composerDraft = Array(repeating: "a line of the draft", count: 6)
            .joined(separator: "\n")
        spin(0.4)
        assertAtBottom(transcript, "with the multi-line draft up")

        // SEND: append the user row AND clear the draft in the SAME turn, then
        // let it settle with no follow-up agent growth.
        say(vm, "user_message_chunk",
            "the multi-line message the user just sent, long enough to wrap a couple of times in this pane")
        vm.composerDraft = ""
        spin(0.6)

        let clip = transcript.contentView
        let materialized = doc.subviews.contains { sub in
            let f = sub.convert(sub.bounds, to: doc)
            return f.intersects(NSRect(origin: clip.bounds.origin, size: clip.bounds.size))
                && f.height > 4
        }
        assertAtBottom(transcript, "after send from a multi-line composer")
        XCTAssertTrue(materialized, "viewport shows blank after send (white screen)")
    }

    /// PROBE A: an overshoot past the content that is followed only by a
    /// COMPOSER shrink (draft clears) — no transcript growth. Mimics send with
    /// nothing streaming yet. The corrector must pull the pinned viewport back.
    func testOvershootCorrectsOnComposerShrinkWithoutGrowth() throws {
        let (vm, surface, window) = makeSurface(rows: 40)
        defer { teardown(surface, window) }
        guard let transcript = transcriptScroll(in: surface),
            let doc = transcript.documentView,
            doc.frame.height > transcript.contentView.bounds.height + 100
        else { throw XCTSkip("hosted transcript did not lay out in this environment") }

        vm.composerDraft = Array(repeating: "draft", count: 6).joined(separator: "\n")
        spin(0.4)

        // Park past the end (the overshoot the white screen leaves us in).
        let clip = transcript.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: doc.frame.height + 200))
        transcript.reflectScrolledClipView(clip)
        spin(0.05)

        // ONLY a composer shrink now — no `say`, so no doc growth.
        vm.composerDraft = ""
        spin(0.6)

        assertAtBottom(transcript, "after composer shrink with no growth")
    }

    /// PROBE B: an overshoot that is followed by NOTHING at all (idle agent).
    /// The pinned viewport must still heal back to the tail rather than sit
    /// stranded in the blank band.
    func testOvershootHealsWhileIdle() throws {
        let (_, surface, window) = makeSurface(rows: 40)
        defer { teardown(surface, window) }
        guard let transcript = transcriptScroll(in: surface),
            let doc = transcript.documentView,
            doc.frame.height > transcript.contentView.bounds.height + 100
        else { throw XCTSkip("hosted transcript did not lay out in this environment") }

        let clip = transcript.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: doc.frame.height + 200))
        transcript.reflectScrolledClipView(clip)
        spin(0.8)

        assertAtBottom(transcript, "after an idle overshoot")
    }

    /// DIAGNOSTIC: how much does the composer's bottom content inset actually
    /// move across draft length + strip presence? If it never crosses the fixed
    /// 110 reserve, composer shrink CANNOT move the transcript geometry.
    func testDiagComposerInset() throws {
        let (vm, surface, window) = makeSurface(rows: 40)
        defer { teardown(surface, window) }
        guard let transcript = transcriptScroll(in: surface) else {
            throw XCTSkip("no layout")
        }
        func inset() -> CGFloat { transcript.contentInsets.bottom }
        vm.composerDraft = ""; spin(0.35)
        let empty = inset()
        vm.composerDraft = Array(repeating: "x", count: 3).joined(separator: "\n"); spin(0.35)
        let threeLine = inset()
        // Turn on the options strip (usage present) with the 3-line draft.
        vm.handle(note(#"{"sessionUpdate":"usage_update","used":1000,"size":200000}"#)); spin(0.35)
        let threeLineStrip = inset()
        vm.composerDraft = ""; spin(0.35)
        let emptyStrip = inset()
        print("INSET empty=\(empty) 3line=\(threeLine) 3line+strip=\(threeLineStrip) empty+strip=\(emptyStrip)")
    }

    func testOvershootPastContentWalksBackOnNextGrowth() throws {
        let (vm, surface, window) = makeSurface(rows: 40)
        defer { teardown(surface, window) }
        guard let transcript = transcriptScroll(in: surface),
            let doc = transcript.documentView,
            doc.frame.height > transcript.contentView.bounds.height + 100
        else { throw XCTSkip("hosted transcript did not lay out in this environment") }

        // Park the viewport past the end — what a lazy-estimate scrollTo
        // overshoot does during a session-restore replay.
        let clip = transcript.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: doc.frame.height + 200))
        transcript.reflectScrolledClipView(clip)
        spin(0.1)

        // The next content growth must clamp the pinned viewport back inside.
        say(vm, "user_message_chunk", "one more row lands and the corrector snaps the tail back")
        spin(0.5)

        assertAtBottom(transcript, "after the overshoot corrector ran")
    }

    func testTranscriptMachineryLeavesComposerScrollAlone() throws {
        let (vm, surface, window) = makeSurface(rows: 12)
        defer { teardown(surface, window) }
        vm.composerDraft = Array(repeating: "draft line", count: 30).joined(separator: "\n")
        spin(0.4)
        guard let composer = composerScroll(in: surface),
            let composerDoc = composer.documentView,
            composerDoc.frame.height > composer.contentView.bounds.height + 40
        else { throw XCTSkip("composer editor did not lay out in this environment") }

        // Reader scrolls up inside the field...
        let clip = composer.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: 10))
        composer.reflectScrolledClipView(clip)
        spin(0.1)

        // ...and transcript streaming must not yank it anywhere.
        for i in 0..<5 { say(vm, "agent_message_chunk", " stream \(i)") }
        spin(0.4)

        XCTAssertEqual(
            clip.bounds.origin.y, 10, accuracy: 2,
            "composer's internal scroll was yanked by transcript machinery")
    }

    /// A big viewport swing (±210 pt, the size of a full slash panel) must
    /// keep a pinned reader glued to the tail at every step.
    func testViewportSwingKeepsPinnedBottom() throws {
        let (_, surface, window) = makeSurface(rows: 40)
        defer { teardown(surface, window) }
        guard let transcript = transcriptScroll(in: surface),
            let doc = transcript.documentView,
            doc.frame.height > transcript.contentView.bounds.height + 100
        else { throw XCTSkip("hosted transcript did not lay out in this environment") }

        assertAtBottom(transcript, "after initial layout")
        window.setContentSize(NSSize(width: 500, height: 390))
        spin(0.5)
        assertAtBottom(transcript, "after the viewport shrank 210 pt")
        window.setContentSize(NSSize(width: 500, height: 600))
        spin(0.5)
        assertAtBottom(transcript, "after the viewport grew back")
    }

    /// Deterministic latency probe: how long from setting "/" until the panel
    /// is on screen, and from clearing it until it's gone. Isolates the code
    /// path from real-app main-thread load.
    func testSlashPanelLatency() async throws {
        let transport = ScriptedAgentTransport()
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection)
        // Heavy transcript (markdown + code fences) like a real session, so
        // any composer→transcript re-render coupling shows up as latency.
        for i in 0..<220 {
            let role = i.isMultiple(of: 2) ? "user_message_chunk" : "agent_message_chunk"
            let body = "row \(i) with **bold**, `code`, and a fence:\\n```swift\\nfunc f\(i)() { print(\(i)) }\\n```\\nand a trailing sentence that wraps in a narrow pane."
            say(vm, role, body)
        }
        let commands = (0..<30).map { #"{"name":"cmd\#($0)","description":"Command number \#($0)"}"# }.joined(separator: ",")
        vm.handle(note(#"{"sessionUpdate":"available_commands_update","availableCommands":[\#(commands)]}"#))

        let surface = AgentChatSurface(session: vm)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.orderFront(nil)
        defer { teardown(surface, window) }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard transcriptScroll(in: surface) != nil else { throw XCTSkip("no layout") }

        func panelUp() -> Bool {
            (window.contentView?.subviews ?? []).contains {
                $0 is NSHostingView<AnyView> && abs($0.frame.width - 380) < 1
            }
        }
        // Poll in 5 ms slices (Task.sleep drains the main queue that the
        // DispatchQueue.main hop rides — RunLoop spinning does not), capped 3 s.
        func waitMs(until cond: () -> Bool) async -> Double {
            let start = Date()
            while !cond(), Date().timeIntervalSince(start) < 3 {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return Date().timeIntervalSince(start) * 1000
        }

        vm.composerDraft = "/"
        let showMs = await waitMs { panelUp() }
        vm.composerDraft = ""
        let hideMs = await waitMs { !panelUp() }
        print("SLASH-LATENCY show=\(Int(showMs))ms hide=\(Int(hideMs))ms")
        XCTAssertLessThan(showMs, 250, "panel too slow to appear")
        XCTAssertLessThan(hideMs, 250, "panel too slow to disappear")
    }

    func testSlashPanelOpenCloseKeepsTranscriptSane() async throws {
        let transport = ScriptedAgentTransport()
        let vm = AgentSessionViewModel(preset: .opencode, cwd: "/tmp")
        let bridge = SessionConnectionBridge()
        bridge.session = vm
        let connection = ACPConnection(transport: transport, handler: bridge)
        await connection.start()
        await vm.bootstrap(connection: connection)
        fillTranscript(vm, rows: 40)
        let commands = (0..<30).map { #"{"name":"cmd\#($0)","description":"Command number \#($0)"}"# }.joined(separator: ",")
        vm.handle(note(#"{"sessionUpdate":"available_commands_update","availableCommands":[\#(commands)]}"#))

        let surface = AgentChatSurface(session: vm)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.orderFront(nil)
        defer { teardown(surface, window) }
        try? await Task.sleep(nanoseconds: 700_000_000)

        guard let transcript = transcriptScroll(in: surface),
            let doc = transcript.documentView,
            doc.frame.height > transcript.contentView.bounds.height + 100
        else { throw XCTSkip("no layout") }
        func materializedIn(_ rect: NSRect) -> Int {
            // Count real (non-scroll-machinery) subviews of the document
            // intersecting the visible rect — 0 with a scrollable doc means
            // the viewport shows BLANK even though geometry looks right.
            var count = 0
            func walk(_ v: NSView, depth: Int) {
                guard depth < 4 else { return }
                for sub in v.subviews {
                    let f = sub.convert(sub.bounds, to: doc)
                    if f.intersects(rect), f.height > 4 { count += 1 }
                    walk(sub, depth: depth + 1)
                }
            }
            walk(doc, depth: 0)
            return count
        }
        func assertHealthy(_ context: String) {
            let clip = transcript.contentView
            assertAtBottom(transcript, context)
            XCTAssertGreaterThan(
                materializedIn(NSRect(origin: clip.bounds.origin, size: clip.bounds.size)), 0,
                "no rows materialized in the viewport (white screen) \(context)")
        }
        assertHealthy("after initial layout")
        let clipSizeBefore = transcript.contentView.bounds.size

        // The floating panel is an NSHostingView the surface adds to the
        // WINDOW (here the surface IS the content view), ~380 pt wide.
        func floatingPanel() -> NSView? {
            (window.contentView?.subviews ?? []).first {
                $0 is NSHostingView<AnyView> && abs($0.frame.width - 380) < 1
            }
        }
        XCTAssertNil(floatingPanel(), "panel present before any slash prefix")

        // Presented in its own in-window layer (no in-bar layout space), so
        // typing / narrowing / deleting a slash prefix must not reflow the
        // conversation — the transcript clip stays exactly as it was and its
        // rows stay materialized (the white-screen guard) — while the panel
        // itself comes and goes, floating clear of the composer field.
        for draft in ["/", "/c", "/cm", "/c", "/", ""] {
            vm.composerDraft = draft
            try? await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertEqual(
                transcript.contentView.bounds.size, clipSizeBefore,
                "slash panel took layout space from the transcript (draft '\(draft)')")
            assertHealthy("with draft '\(draft)'")
            if draft.isEmpty {
                XCTAssertNil(floatingPanel(), "panel still up after the prefix was deleted")
            } else if let panel = floatingPanel(), let field = composerScroll(in: surface) {
                // The panel sits above the field (flipped content view: smaller
                // y is higher) and stays inside the window.
                let fieldTop = field.convert(field.bounds, to: window.contentView).minY
                XCTAssertLessThanOrEqual(
                    panel.frame.maxY, fieldTop + 1,
                    "panel overlaps the composer field for draft '\(draft)'")
                XCTAssertGreaterThanOrEqual(
                    panel.frame.minY, -1, "panel clipped past the window top")
            } else {
                XCTFail("no floating panel for draft '\(draft)'")
            }
        }
    }
}

#endif
