#if os(macOS)
import XCTest
import BentoLink
import BentoTerminalPane
import BentoWorkbench
@testable import BentoTmuxPane

// The whole tower against a REAL bento-daemon over its unix socket — the
// Swift twin of the Go side's tmuxpane_live_test.go, but through the
// client stack instead of a bare wire rig: build the daemon binary, start
// it in an isolated BENTO_HOME, then ensure → statechanged snapshot →
// TmuxPaneRuntime over LinkTmuxTransport (type a marker, watch sequenced
// units render) → splitPane through DaemonAuthority (structureApplied rev,
// mirror ingest) → reattach with the cursor and get the tail only.
//
// Isolation is not optional (CLAUDE.md: never touch the user's daemon):
// BENTO_HOME points at a throwaway dir, the tmux server lives on a private
// -L socket via a BENTO_TMUX shim, and the only process signalled is the
// one this test spawned.

@MainActor
final class LiveDaemonRoundTripTests: XCTestCase {
    private struct LiveTimeout: Error {}

    /// Accumulates pane bytes off the runtime/transport callbacks.
    private final class TextLog: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) {
            lock.lock()
            data.append(d)
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
        func reset() {
            lock.lock()
            data.removeAll()
            lock.unlock()
        }
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 20,
                           _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(label)")
                throw LiveTimeout()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// PATH lookup with the launchd-minimal-PATH fallbacks the daemon
    /// itself uses.
    private func findTool(_ name: String) -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/usr/local/go/bin"]
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String], cwd: String? = nil,
                     env: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    func testLiveDaemonTmuxRoundTrip() async throws {
        guard let go = findTool("go") else {
            throw XCTSkip("go not installed — live daemon round-trip skipped")
        }
        guard let tmux = findTool("tmux") else {
            throw XCTSkip("tmux not installed — live daemon round-trip skipped")
        }
        let repoRoot = URL(fileURLWithPath: #filePath)          // tests/BentoTmuxPaneTests/…
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        // Short base path on purpose: BENTO_HOME holds acp.sock, and unix
        // socket paths cap at 104 bytes on macOS — the default per-test
        // temp dir already burns most of that.
        let base = "/tmp/bento-live-\(UInt32.random(in: 0x1000...0xFFFF))"
        let fm = FileManager.default
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(atPath: base) }
        let home = base + "/home"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)

        // --- build the daemon (read-only for the repo: output goes to base) ---
        let daemonBin = base + "/bento-daemon"
        let build = try run(go, ["build", "-o", daemonBin, "./cmd/bento-daemon"],
                            cwd: repoRoot.appendingPathComponent("daemon").path)
        guard build.status == 0 else {
            XCTFail("go build failed:\n\(build.output)")
            return
        }

        // --- private tmux server: a BENTO_TMUX shim rewrites the daemon's
        // pinned production socket (-L bento-acp) to this run's own, with a
        // fixture config (default-shell /bin/sh, like the Go live tests, so
        // pane echo is plain and markers deterministic) ---
        let socketName = "bento-swift-live-\(ProcessInfo.processInfo.processIdentifier)"
        let conf = base + "/tmux.conf"
        try "set -g default-shell /bin/sh\n".write(toFile: conf, atomically: true, encoding: .utf8)
        let shim = base + "/tmux-shim.sh"
        try """
        #!/bin/sh
        if [ "$1" = "-L" ]; then shift 2; fi
        exec "\(tmux)" -L "\(socketName)" -f "\(conf)" "$@"
        """.write(toFile: shim, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim)
        addTeardownBlock { [self] in
            _ = try? run(tmux, ["-L", socketName, "kill-server"])
        }

        // --- start the daemon (isolated home; relay pointed at a dead port,
        // which its client just retries against) ---
        let daemonLog = base + "/daemon.log"
        fm.createFile(atPath: daemonLog, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: daemonLog))
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: daemonBin)
        daemon.arguments = ["start", "--relay", "http://127.0.0.1:9"]
        var env = ProcessInfo.processInfo.environment
        env["BENTO_HOME"] = home
        env["BENTO_TMUX"] = shim
        daemon.environment = env
        daemon.standardOutput = logHandle
        daemon.standardError = logHandle
        try daemon.run()
        addTeardownBlock {
            // SIGTERM the one process this test spawned — never a pkill.
            guard daemon.isRunning else { return }
            daemon.terminate()
            for _ in 0..<50 where daemon.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if daemon.isRunning { kill(daemon.processIdentifier, SIGKILL) }
        }

        let socketPath = home + "/acp.sock"
        do {
            try await waitUntil("daemon socket", timeout: 15) {
                fm.fileExists(atPath: socketPath)
            }
        } catch {
            let log = (try? String(contentsOfFile: daemonLog, encoding: .utf8)) ?? ""
            XCTFail("daemon never came up; log tail:\n\(log.suffix(2000))")
            return
        }

        // --- control stream: authority wired to the statechanged feed ---
        let control = AcpHostTransportFactory.local(socketPath: socketPath)
        try await control.connect()
        addTeardownBlock { control.close() }
        let authority = await DaemonAuthority.linked(to: control, target: "local", entryID: 1)
        XCTAssertNil(authority.lastState, "nothing ensured yet — the mirror key must be empty")

        // Ensure fans the mirror write out as statechanged BEFORE the ack
        // lands; ingest below therefore proves the change-stream route, not
        // the initial pull (which ran on the empty key above).
        _ = try await control.ensureTmux(sessionName: "bento")
        try await waitUntil("statechanged → ingest") { authority.lastState != nil }
        let first = try XCTUnwrap(authority.lastState)
        XCTAssertEqual(first.target, "local")
        XCTAssertEqual(first.session, "bento")
        XCTAssertEqual(first.structure.windows.count, 1)
        let firstPanes = first.structure.windows[0].panes
        XCTAssertEqual(firstPanes.count, 1, "fresh session is one window, one pane")
        let paneID = firstPanes[0]
        print("LIVE: statechanged snapshot rev=\(first.rev) session=\(first.session) panes=\(firstPanes)")

        // --- pane runtime over the real byte transport ---
        let instance = TmuxVirtualInstanceID(target: "local", pane: TmuxPaneID(paneID))
        let paneLog = TextLog()
        let transport = LinkTmuxTransport(instanceID: instance, sessionName: "bento") {
            AcpHostTransportFactory.local(socketPath: socketPath)
        }
        let runtime = TmuxPaneRuntime(instanceID: instance, transport: transport)
        runtime.onOutput = { paneLog.append($0) }
        runtime.attach()
        try await waitUntil("pane ready") { runtime.phase == .ready }

        // Marker split in the typed line (the Go live tests' trick) so the
        // shell's echo of our keystrokes can never satisfy the match — only
        // printf's actual output can.
        runtime.send("printf 'BEN''TO_SWIFT_M1\\n'")
        try await waitUntil("marker one output") { paneLog.text.contains("BENTO_SWIFT_M1") }
        XCTAssertGreaterThan(runtime.updateSeq, 0, "units consumed ⇒ cursor advanced")
        print("LIVE: marker one rendered; cursor=\(runtime.updateSeq)")

        // --- structure verb: splitPane → structureApplied rev → ingest ---
        var ack: Result<UInt64, Error>?
        authority.onStructureResult = { _, result in ack = result }
        authority.apply(.splitPane(session: "bento", target: paneID, horizontal: true,
                                   cwd: nil, command: nil))
        try await waitUntil("structureApplied ack") { ack != nil }
        let ackRev = try XCTUnwrap(ack).get()
        XCTAssertGreaterThan(ackRev, first.rev, "the ack rev includes the split")
        try await waitUntil("mirror shows the split") {
            guard let state = authority.lastState, state.rev >= ackRev else { return false }
            return state.structure.windows.reduce(0) { $0 + $1.panes.count } == 2
        }
        let split = try XCTUnwrap(authority.lastState)
        let entry = try XCTUnwrap(split.workspaceEntry(entryID: 1))
        XCTAssertEqual(entry.panes.count, 2, "the projection carries both panes")
        print("LIVE: structureApplied rev=\(ackRev); mirror rev=\(split.rev) panes=\(entry.panes.map(\.id))")

        // --- reattach with the cursor: tail only ---
        let cursor = runtime.updateSeq
        runtime.shutdown()

        // While the original viewer is away, a second viewer types marker
        // two (writes need an attached stream; the pane's log keeps growing
        // regardless of who watches).
        let writer = LinkTmuxTransport(instanceID: instance, sessionName: "bento") {
            AcpHostTransportFactory.local(socketPath: socketPath)
        }
        let writerLog = TextLog()
        let writerAttachment = try await writer.attach(haveSeq: 0)
        let writerPump = Task { @MainActor in
            for await event in writerAttachment.events {
                if case .output(let d) = event { writerLog.append(d) }
            }
        }
        writer.write(Data("printf 'BEN''TO_SWIFT_M2\\n'\r".utf8))
        try await waitUntil("marker two logged") { writerLog.text.contains("BENTO_SWIFT_M2") }
        writer.detach()
        writerPump.cancel()

        paneLog.reset()
        runtime.attach()
        try await waitUntil("tail replay") { paneLog.text.contains("BENTO_SWIFT_M2") }
        XCTAssertFalse(paneLog.text.contains("BENTO_SWIFT_M1"),
                       "haveSeq=\(cursor) must replay only the tail — marker one came back")
        XCTAssertGreaterThan(runtime.updateSeq, cursor, "the tail advanced the cursor")
        print("LIVE: reattach from cursor=\(cursor) replayed tail only; cursor now \(runtime.updateSeq)")

        runtime.shutdown()
    }
}
#endif
