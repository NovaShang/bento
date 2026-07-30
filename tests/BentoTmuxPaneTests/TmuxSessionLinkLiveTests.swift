#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoTermLink
import BentoWorkbench
import Foundation
import SwiftTmux
import Testing
@testable import BentoTmuxPane

// The acceptance gate for taking Bento Term off the daemon: a real tmux, a
// real pty, a real control-mode parse, and the structure state that comes out
// the far end — the whole client-side stack with nothing stubbed.
//
// Isolation: every run spawns its own `-L` server with `-f /dev/null`, so it
// can never see, resize, or kill anything on the user's tmux — including the
// agents that may be running this very test.

@MainActor
@Suite("tmux session link, live", .enabled(if: LiveTmuxServer.isAvailable))
struct TmuxSessionLinkLiveTests {
    @Test func attachesAndReadsItsOwnStructure() async throws {
        let server = try LiveTmuxServer()
        defer { server.kill() }
        try server.run(["new-session", "-d", "-s", "work", "-n", "main"])

        let link = server.connectLink()
        await link.connect(host: Host(), cols: 120, rows: 40, launch: .spawnedByTransport)
        defer { link.disconnect() }

        let state = try #require(await server.awaitState(link))
        #expect(state.session == "work")
        #expect(state.structure.windows.count == 1)
        let window = try #require(state.structure.windows.first)
        #expect(window.name == "main")
        #expect(window.panes.count == 1)
        // Geometry is a READING of tmux's own listing, so it must be real.
        #expect(window.details.first?.width ?? 0 > 0)
        #expect(window.details.first?.active == true)
    }

    /// A split is a structure VERB, and the tree that comes back is tmux's
    /// answer — never a local mutation. Two panes must appear without anyone
    /// having touched a client-side tree.
    @Test func splitVerbLandsAndTheTreeFollows() async throws {
        let server = try LiveTmuxServer()
        defer { server.kill() }
        try server.run(["new-session", "-d", "-s", "work"])

        let link = server.connectLink()
        await link.connect(host: Host(), cols: 120, rows: 40, launch: .spawnedByTransport)
        defer { link.disconnect() }

        let before = try #require(await server.awaitState(link))
        let pane = try #require(before.structure.windows.first?.panes.first)

        var latest: TmuxStructureState?
        let authority = TmuxAuthority(link: link)
        authority.onState = { latest = $0 }

        authority.apply(.splitPane(session: "work", target: pane, horizontal: true,
                                   cwd: nil, command: nil))

        try await server.until { latest?.structure.windows.first?.panes.count == 2 }
        let after = try #require(latest)
        #expect(after.structure.windows.first?.panes.count == 2)
        #expect(after.rev > before.rev)
    }

    /// `%output` has to reach the pane that produced it and no other. This is
    /// seam one end to end: shell → tmux → control mode → fan-out → transport.
    @Test func paneOutputReachesItsOwnTransport() async throws {
        let server = try LiveTmuxServer()
        defer { server.kill() }
        try server.run(["new-session", "-d", "-s", "work"])

        let link = server.connectLink()
        await link.connect(host: Host(), cols: 120, rows: 40, launch: .spawnedByTransport)
        defer { link.disconnect() }

        let state = try #require(await server.awaitState(link))
        let paneID = try #require(state.structure.windows.first?.panes.first)
        let pane = TmuxPaneID(paneID)

        let transport = ControlModeTmuxTransport(pane: pane, link: link)
        let attachment = try await transport.attach(haveSeq: 0)
        // No daemon log to resume from, and the runtime is told so plainly.
        #expect(attachment.details.replay == false)
        #expect(attachment.details.headSeq == 0)

        let seen = Collected()
        let pump = Task {
            for await event in attachment.events {
                if case .output(let data) = event { seen.append(data) }
            }
        }
        defer { pump.cancel() }

        transport.write(Data("echo bento-marker\n".utf8))
        try await server.until { seen.text.contains("bento-marker") }
        #expect(seen.text.contains("bento-marker"))
    }
}

/// Thread-safe accumulator for stream output.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A throwaway tmux server on its own socket, plus the link that drives it.
@MainActor
final class LiveTmuxServer {
    nonisolated static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Self.tmuxPath)
    }

    nonisolated(unsafe) static let tmuxPath: String = {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/tmux"
    }()

    let socket: String

    init() throws {
        socket = "bento-link-test-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0 ..< .max))"
    }

    /// `-f /dev/null`: the user's tmux.conf must not reach this server, or a
    /// local `set -g` could change what the test is measuring.
    private var baseArgs: [String] { ["-L", socket, "-f", "/dev/null"] }

    @discardableResult
    func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        process.arguments = baseArgs + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    func kill() {
        _ = try? run(["kill-server"])
    }

    /// A link whose pty spawns tmux directly — the macOS shape, and the only
    /// one that can be pinned to a test socket.
    func connectLink(session: String = "work") -> TmuxSessionLink {
        let transport = LocalPtyTransport(
            command: [Self.tmuxPath] + baseArgs + ["-CC", "attach", "-t", session])
        return TmuxSessionLink(transport: transport, target: "test", sessionName: session)
    }

    /// The first structure state the link publishes after connecting.
    func awaitState(_ link: TmuxSessionLink) async -> TmuxStructureState? {
        var captured: TmuxStructureState?
        link.onState = { captured = $0 }
        await link.refreshStructure()
        for _ in 0 ..< 50 where captured == nil {
            try? await Task.sleep(for: .milliseconds(100))
            await link.refreshStructure()
        }
        return captured
    }

    /// Poll a condition rather than sleeping a guessed interval.
    func until(_ condition: () -> Bool, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("condition never became true within \(timeout)")
    }
}
#endif
