import BentoFoundation
import BentoTermLink
import BentoTerminalPane
import Foundation
import SwiftTmux
import os

// The client-side replacement for `TermDaemonLink`: ONE tmux control-mode
// connection per window, owned here, with no daemon anywhere in the picture.
//
// The shape is the pre-merge product's, restored: a `TerminalTransport`
// carries bytes (a local pty, or that same pty running `ssh host …`, or
// Citadel on iOS), `TmuxControlMode` parses them, and everything above reads
// tmux's own answers. What changed is only where the parse happens — here
// instead of in the daemon — which is what lets a remote host be any machine
// the user can already ssh to, with nothing installed on it.
//
// Two consumers sit on top, one per seam:
//   * `ControlModeTmuxTransport` (seam one) — per-pane bytes, `%output` in,
//     `send-keys -H` out.
//   * `TmuxAuthority` (seam two) — structure verbs down, snapshots up.
// Neither knows about the transport underneath, and `TmuxPaneRuntime` /
// `TmuxStructureProjection` above them did not have to change at all.

/// One tmux server reached over one byte channel: the control client, the
/// per-pane output fan-out, and the structure snapshots.
@MainActor
public final class TmuxSessionLink {
    private static let log = Logger(subsystem: "com.bento.tmuxpane", category: "sessionlink")

    /// The parsed control client. `package` so the authority can send commands
    /// through the same FIFO the link uses.
    package let control = TmuxControlMode()

    private let transport: any TerminalTransport

    /// Target label carried into every `TmuxStructureState` (`"local"`, or a
    /// host alias). Identifies the machine, never the session.
    public let target: String

    /// The session this link attached to. One window = one session = one host,
    /// so this is set once at connect and only moves if tmux renames it.
    public private(set) var sessionName: String

    /// Bumped on every published snapshot — the projection's staleness guard.
    /// Local and monotonic; there is no server minting revs for us now.
    private var rev: UInt64 = 0

    /// Per-pane output sinks, registered by `ControlModeTmuxTransport`.
    private var paneSinks: [TmuxPaneID: (Data) -> Void] = [:]
    /// Panes whose sink went away mid-attach still need their bytes dropped
    /// rather than buffered forever; nothing else is remembered about them.

    /// Fan-out of every freshly built structure state — wired to
    /// `TmuxAuthority.ingest`, which is what feeds the workspace store.
    package var onState: ((TmuxStructureState) -> Void)?

    /// Raised when the byte channel dies under us. The shell decides whether
    /// that is a reconnect or a teardown; the link does not.
    public var onConnectionStateChanged: ((TerminalConnectionState) -> Void)?

    /// Bytes are parsed OFF the main thread. Under heavy TUI output the
    /// control-mode parse is the main thread's biggest contender with
    /// keyDown, and a keystroke's own echo used to queue behind it.
    private let parseQueue = DispatchQueue(label: "com.bento.tmux.parse", qos: .userInteractive)

    /// Coalesces the metadata refresh that follows a structural notification.
    /// Geometry is applied synchronously from the `%layout-change` string (see
    /// `handle`); this debounce is for everything a layout string can't say.
    private var refreshDebounce: Task<Void, Never>?

    private var connected = false

    public init(transport: any TerminalTransport, target: String, sessionName: String) {
        self.transport = transport
        self.target = target
        self.sessionName = sessionName
        wire()
    }

    // MARK: - Wiring

    private func wire() {
        control.sendToSSH = { [weak self] string in
            guard let data = string.data(using: .utf8) else { return }
            self?.transport.write(data)
        }
        control.onNotification = { [weak self] notification in
            Task { @MainActor in self?.handle(notification) }
        }
        // Everything funnels through the serial parse queue, so byte order
        // survives whichever thread the transport delivers on.
        transport.onDataReceived = { [weak self] data in
            guard let self else { return }
            self.parseQueue.async { self.control.feedData(data) }
        }
        transport.onStateChanged = { [weak self] state in
            Task { @MainActor in self?.onConnectionStateChanged?(state) }
        }
    }

    // MARK: - Lifecycle

    /// How tmux gets started on the far end.
    ///
    /// The two platforms genuinely differ here, so the difference is named
    /// rather than papered over. macOS owns the pty's argv, so it can spawn
    /// `tmux -CC …` (or `ssh host tmux -CC …`) directly and skip the shell
    /// entirely. iOS's SSH channel hands back a login SHELL, so the launch
    /// line has to be typed into it — and that typing races the shell's own
    /// startup, which is why the greeting is awaited rather than slept on.
    public enum Launch: Sendable {
        /// The transport's command already IS the tmux invocation.
        case spawnedByTransport
        /// Type `tmux -CC new-session -A …` into the shell the transport
        /// opened. `cwd`/`command` seed the session only when `-A` has to
        /// CREATE it — re-attaching must never relaunch the agent, which is
        /// exactly what tmux's own `-A` semantics give us.
        case typedIntoShell(cwd: String? = nil, command: String? = nil)
    }

    /// Dial the host, start the shell, and attach the control client.
    public func connect(host: BentoFoundation.Host, cols: Int, rows: Int,
                        launch: Launch = .typedIntoShell()) async {
        await transport.connect(host: host)
        transport.startShell(cols: cols, rows: rows)

        if case .typedIntoShell(let cwd, let command) = launch {
            let line = control.launchCommand(
                sessionName: sessionName, path: cwd, command: command)
            Self.log.info("launching tmux: \(line.trimmingCharacters(in: .newlines), privacy: .public)")
            transport.write(line)
        }

        // Wait for the -CC greeting rather than sleeping a fixed interval:
        // commands sent before tmux attaches get typed into the plain login
        // shell. Faster than a sleep when the shell is quick, and tolerant
        // when it is slow (a fresh login shell runs the whole rc first).
        if await control.awaitControlMode(timeout: .seconds(12)) == false {
            Self.log.warning("tmux -CC greeting not seen in 12s — proceeding anyway")
        }
        control.sendFireAndForget(.refreshClient(width: cols, height: rows))

        connected = true
        await refreshStructure()
    }

    public func disconnect() {
        connected = false
        refreshDebounce?.cancel()
        refreshDebounce = nil
        paneSinks.removeAll()
        transport.disconnect()
        control.reset()
    }

    /// Cheap end-to-end liveness check for a connection that CLAIMS to be up —
    /// used on foreground-resume, where a socket that survived suspension
    /// should be kept rather than torn down just because a timer expired.
    public func probeLiveness() async -> Bool {
        await transport.probeLiveness()
    }

    /// Whether the bytes ride a local pipe. Not cosmetic: a deep
    /// `capture-pane` seed is nearly free on a pty and expensive over SSH,
    /// where a phone also decrypts and drains every byte.
    public var isLocalLink: Bool { transport.isLocalLink }

    // MARK: - Pane fan-out (seam one's supply)

    package func subscribe(pane: TmuxPaneID, sink: @escaping (Data) -> Void) {
        paneSinks[pane] = sink
    }

    package func unsubscribe(pane: TmuxPaneID) {
        paneSinks.removeValue(forKey: pane)
    }

    package func write(to pane: TmuxPaneID, data: Data) {
        control.sendData(to: pane, data: data)
    }

    package func resize(pane: TmuxPaneID, cols: Int, rows: Int) {
        control.sendFireAndForget(.resizePane(id: pane, width: cols, height: rows))
    }

    /// A pane's scrollback, for `TmuxPaneRuntime.captureScrollback`. Bounded
    /// by `lines` because on a remote link every one of them is paid for.
    package func capture(pane: TmuxPaneID, lines: Int) async -> Data? {
        let response = await control.send(.capturePane(id: pane, lines: lines, escapes: true))
        guard !response.isError else { return nil }
        return Data(response.output.utf8)
    }

    // MARK: - Commands (seam two's supply)

    @discardableResult
    package func send(_ command: TmuxCommand) async -> TmuxCommandResponse {
        await control.send(command)
    }

    // MARK: - Notifications

    private func handle(_ notification: TmuxNotification) {
        switch notification {
        case .output(let pane, let data):
            paneSinks[pane]?(data)

        case .layoutChange:
            // tmux delivers %layout-change BEFORE the program's post-SIGWINCH
            // repaint in this same ordered stream, so the structure has to be
            // republished now — a surface still at the old size when the
            // repaint arrives wraps it into a stale grid and stays garbled
            // until something resizes again. The debounce below is for the
            // metadata a layout string cannot carry (titles, flags, adds and
            // removes), not for geometry.
            scheduleRefresh(immediate: true)

        case .windowAdd, .windowClose, .windowRenamed, .paneModeChanged:
            scheduleRefresh(immediate: false)

        case .sessionChanged(_, let name):
            sessionName = name
            scheduleRefresh(immediate: false)

        case .sessionRenamed(_, let name):
            // Modern tmux names the session that was renamed, which is not
            // necessarily ours — but the snapshot lists every session anyway,
            // so one refresh answers either case.
            if !name.isEmpty { sessionName = name }
            scheduleRefresh(immediate: false)

        case .clientDetached:
            // Another client left. Ours is still here — but the session's size
            // authority may have just changed hands, so re-read.
            scheduleRefresh(immediate: false)

        case .exit:
            connected = false
        }
    }

    private func scheduleRefresh(immediate: Bool) {
        refreshDebounce?.cancel()
        if immediate {
            Task { await refreshStructure() }
            return
        }
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshStructure()
        }
    }

    // MARK: - Structure snapshots

    /// Read tmux's own listings and publish one `TmuxStructureState`.
    ///
    /// This is the whole of "the tmux server is the structure authority" on
    /// the client: two listings, no local tree, no optimistic mutation. The
    /// daemon used to run exactly these two commands and mirror the result
    /// through statekv; the only thing that moved is which process asks.
    package func refreshStructure() async {
        guard connected else { return }

        let windowsResponse = await control.send(.listWindows())
        guard !windowsResponse.isError else { return }
        let windows = TmuxParsers.parseWindowList(windowsResponse.output)

        // `-s` lists every pane in the session, so one round trip covers all
        // windows instead of one per window.
        let panesResponse = await control.send(
            .listPanes(target: sessionName, sessionWide: true))
        guard !panesResponse.isError else { return }
        let panes = TmuxParsers.parsePaneList(panesResponse.output)

        rev &+= 1
        let snapshot = Self.buildSnapshot(windows: windows, panes: panes)
        onState?(TmuxStructureState(
            rev: rev, target: target, session: sessionName, structure: snapshot))
    }

    /// Map tmux's listings onto the wire shape the projection already reads.
    ///
    /// Pane→window attribution comes from `#{window_id}` in the pane listing
    /// (the pane parser carries it) rather than from a per-window listing, so
    /// a pane that moved between the two round trips lands in exactly one
    /// window instead of none or both.
    static func buildSnapshot(windows: [TmuxWindow], panes: [SwiftTmux.Pane]) -> TmuxStructureSnapshot {
        var byWindow: [TmuxWindowID: [SwiftTmux.Pane]] = [:]
        for pane in panes {
            guard let window = pane.windowID else { continue }
            byWindow[window, default: []].append(pane)
        }
        let snapshotWindows = windows.map { window -> TmuxSnapshotWindow in
            let members = byWindow[window.id] ?? window.panes
            let details = members.map { pane in
                TmuxSnapshotPane(
                    id: pane.id.raw,
                    title: pane.title ?? "",
                    width: pane.width, height: pane.height,
                    x: pane.x, y: pane.y,
                    active: pane.isActive, zoomed: pane.isZoomed)
            }
            return TmuxSnapshotWindow(
                index: window.index ?? 0,
                name: window.name,
                layout: window.layout ?? "",
                active: window.isActive,
                panes: details.map(\.id),
                details: details)
        }
        return TmuxStructureSnapshot(windows: snapshotWindows)
    }
}
