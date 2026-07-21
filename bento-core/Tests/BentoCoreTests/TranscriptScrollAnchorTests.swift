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

    /// Distance from the viewport's bottom edge to the document's bottom.
    /// ~0 = at the tail; negative = parked PAST the content (blank space).
    private func bottomGap(_ scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView
        let docH = clip.documentView?.frame.height ?? 0
        return docH - clip.bounds.height - clip.bounds.origin.y
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

        // The panel floats in a menu-like child window, so typing /
        // narrowing / deleting a slash prefix must not reflow the
        // conversation at all — and the child window must come and go.
        for draft in ["/", "/c", "/cm", "/c", "/", ""] {
            vm.composerDraft = draft
            try? await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertEqual(
                transcript.contentView.bounds.size, clipSizeBefore,
                "slash panel took layout space from the transcript (draft '\(draft)')")
            assertHealthy("with draft '\(draft)'")
            let children = window.childWindows ?? []
            if draft.isEmpty {
                XCTAssertTrue(
                    children.allSatisfy { !$0.isVisible },
                    "slash panel window still visible after the prefix was deleted")
            } else {
                XCTAssertTrue(
                    children.contains { $0.isVisible && $0.frame.width > 100 },
                    "no visible slash panel child window for draft '\(draft)'")
            }
        }
    }
}

#endif
