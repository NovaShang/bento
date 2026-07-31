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

    /// tmux's own id for the session this client is on, learned from
    /// `%session-changed`. Names are labels and can be reused; this is what
    /// makes "was the session that got renamed OURS?" answerable.
    private var currentSessionID: TmuxSessionID?

    /// Last known height per pane, for the reattach reseed (one screen each).
    private var paneHeights: [TmuxPaneID: Int] = [:]

    /// In-flight / wanted-again flags for `refreshStructure`.
    private var refreshing = false
    private var refreshWanted = false

    /// Per-pane output sinks, registered by `ControlModeTmuxTransport`.
    private var paneSinks: [TmuxPaneID: (Data) -> Void] = [:]
    /// Panes whose sink went away mid-attach still need their bytes dropped
    /// rather than buffered forever; nothing else is remembered about them.

    /// Fan-out of every freshly built structure state — wired to
    /// `TmuxAuthority.ingest`, which is what feeds the workspace store.
    package var onState: ((TmuxStructureState) -> Void)?

    /// Where this connection is. Published so a shell can show the user a
    /// "Reconnecting…" banner instead of a frozen screen — the pre-merge
    /// product drove exactly such a banner off `isReconnecting`, and its
    /// absence is why a dead link looked identical to an idle one.
    public enum Phase: Sendable, Equatable {
        case connecting
        case ready
        /// The byte channel died and the loop below is bringing it back.
        case reconnecting
        /// tmux said `%exit`, or the user left. Terminal; nothing retries.
        case ended
    }

    public private(set) var phase: Phase = .connecting {
        didSet { if oldValue != phase { onPhaseChanged?(phase) } }
    }

    public var onPhaseChanged: ((Phase) -> Void)?

    /// Raised when the byte channel dies under us. Informational now — the
    /// link recovers itself (see `handleUnexpectedFailure`), because whoever
    /// owns the transport is the only one who can reattach WITHOUT replacing
    /// this object, and replacing it is what left every pane's transport
    /// pointing at a dead link.
    public var onConnectionStateChanged: ((TerminalConnectionState) -> Void)?

    // MARK: - Reconnect state
    //
    // The whole block below is the pre-merge product's connection lifecycle
    // (`TerminalViewModel`), moved here because here is where the transport
    // is. The daemon-era rewrite left it out entirely: a dropped link had no
    // recovery on iOS at all, and on macOS the shell "recovered" by building a
    // NEW link — which every `ControlModeTmuxTransport` held weakly, so every
    // pane went permanently deaf while the reconnect reported success.

    /// Set by `disconnect()`. A user who left must never be dragged back.
    private var userInitiatedDisconnect = false
    /// True between `suspendForBackground` and `resumeFromBackground`. iOS
    /// freezes the process; a failure seen there is expected, not a fault.
    private var isInBackground = false
    private var phaseBeforeSuspend: Phase?
    private var reconnectTask: Task<Void, Never>?
    /// Instance state, not a local: a host that fails instantly used to retry
    /// forever at the first backoff step because the counter lived in the call.
    private var reconnectAttempt = 0
    /// A reattach that brought tmux up and THEN lost the socket — most often
    /// during the seed burst, which is the heaviest traffic the connection
    /// ever carries — must not be reported as a success.
    private var failedDuringReattach = false
    /// Two consecutive command timeouts = the transport is half-dead in a way
    /// no layer reported. See `noteCommandTimeout`.
    private var commandTimeoutStreak = 0

    /// Connect arguments, kept so a reattach can repeat them.
    private var host: BentoFoundation.Host?
    private var launch: Launch = .typedIntoShell()
    /// The viewport this client last declared. `refresh-client` is a property
    /// of the CLIENT, and a reconnect is a new client, so it has to be
    /// re-declared — a resize that fired before the transport was up is
    /// otherwise lost, leaving the remote pty a different width than what is
    /// rendered.
    private var declaredSize: (cols: Int, rows: Int) = (80, 24)

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
            Task { @MainActor in
                self?.onConnectionStateChanged?(state)
                self?.handleTransportState(state)
            }
        }
    }

    /// Both shapes of death are the same event. Citadel reports a dead channel
    /// as `.failed` and a dead client as `.disconnected`; the pty reports
    /// `.disconnected`. Handling only one of them is how a single dropped
    /// packet left the link "dead but looking alive".
    private func handleTransportState(_ state: TerminalConnectionState) {
        switch state {
        case .failed(let message): handleUnexpectedFailure(message: message)
        case .disconnected:        handleUnexpectedFailure(message: "connection closed")
        case .connecting, .connected: break
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
        ///
        /// `groupWith` names a session to JOIN rather than attach to: tmux
        /// makes a second session sharing the first's windows
        /// (`new-session -t`). That is how this product supports several
        /// devices on the same work — same windows, but each session carries
        /// its own size, so a phone and a Mac stop fighting over geometry
        /// instead of one crushing the other. Seeding a directory or program
        /// is meaningless for a grouped session and tmux rejects the
        /// combination, so those are ignored when it is set.
        case typedIntoShell(cwd: String? = nil, command: String? = nil,
                            groupWith: String? = nil)
    }

    /// Whether this client may impose its own size on the session.
    ///
    /// Restored from the pre-merge product, where it was the `resizeToScreen`
    /// flag: *"Only resize the tmux client viewport when we created a new
    /// standalone session, since shrinking a shared session would also shrink
    /// the desktop's view."*
    ///
    /// tmux resolves a session's size from its attached clients, and the
    /// default `window-size latest` means the newest client wins. So a phone
    /// that attaches to a session a Mac is working in silently crushes that
    /// Mac's panes down to phone dimensions — observed twice against live
    /// work while this guard was missing. Declaring a size is therefore a
    /// right you earn by CREATING the session, not something every client
    /// does on arrival.
    public enum SizeClaim: Sendable {
        /// We created this session; its size is ours to set.
        case declareOurs
        /// Someone else's session, or one that already existed. Take it as it
        /// is — the view can overflow and the user scrolls.
        case adoptExisting
    }

    /// Dial the host, start the shell, and attach the control client.
    public func connect(host: BentoFoundation.Host, cols: Int, rows: Int,
                        launch: Launch = .typedIntoShell(),
                        size: SizeClaim = .adoptExisting) async {
        self.host = host
        self.launch = launch
        self.declaredSize = (cols, rows)
        userInitiatedDisconnect = false
        phase = .connecting
        _ = await bringUp(size: size, joiningGroup: true)
    }

    /// One attach attempt, start to finish. Shared by the first connect and
    /// every reattach, so the two can never drift.
    ///
    /// `joiningGroup` is false on a reattach: our own (possibly grouped)
    /// session already exists by then, and `new-session -A -s <ours>` simply
    /// re-attaches it. Passing `-t` again would ask tmux for a SECOND grouped
    /// session every time the Wi-Fi blinked.
    @discardableResult
    private func bringUp(size: SizeClaim, joiningGroup: Bool) async -> Bool {
        guard let host else { return false }
        await transport.connect(host: host)
        guard case .connected = transport.state else {
            Self.log.warning("transport did not come up")
            return false
        }
        transport.startShell(cols: declaredSize.cols, rows: declaredSize.rows)

        if case .typedIntoShell(let cwd, let command, let groupWith) = launch {
            let line = control.launchCommand(
                sessionName: sessionName,
                groupWith: joiningGroup ? groupWith : nil,
                path: cwd, command: command)
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
        if case .declareOurs = size {
            Self.log.info("claiming session size \(self.declaredSize.cols)x\(self.declaredSize.rows)")
            control.sendFireAndForget(
                .refreshClient(width: declaredSize.cols, height: declaredSize.rows))
            // The old product slept 300ms here before listing, so the size it
            // just asked for is the size the first snapshot reports.
            try? await Task.sleep(for: .milliseconds(300))
        }

        connected = true
        commandTimeoutStreak = 0
        phase = .ready
        await refreshStructure()
        return true
    }

    /// The user left this session. Terminal — nothing here retries.
    public func disconnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connected = false
        refreshDebounce?.cancel()
        refreshDebounce = nil
        paneSinks.removeAll()
        transport.disconnect()
        control.reset()
        phase = .ended
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

    /// Declare this client's viewport. `refresh-client -C` is how a tmux
    /// client states its size; the server resolves the session's size from
    /// every attached client per the `window-size` policy. Remembered so a
    /// reconnect — which is a NEW tmux client — can restate it.
    public func declareViewport(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        declaredSize = (cols, rows)
        guard connected else { return }
        control.sendFireAndForget(.refreshClient(width: cols, height: rows))
    }

    // MARK: - Background / foreground

    /// The app went away. iOS freezes the process, so any in-flight reconnect
    /// would only burn the backoff counter while suspended and then surface a
    /// bogus failure on unlock.
    public func suspendForBackground() {
        isInBackground = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        refreshDebounce?.cancel()
        refreshDebounce = nil
        switch phase {
        case .ready:
            phaseBeforeSuspend = phase
        case .connecting, .reconnecting:
            phaseBeforeSuspend = nil
        case .ended:
            return
        }
        phase = .connecting
    }

    /// The app came back. The socket usually SURVIVES a suspension — iOS
    /// freezes the process, it does not close TCP — so probe before tearing
    /// anything down. Tearing down a healthy connection here is the whole of
    /// "it reconnects on every unlock even though nothing was wrong".
    public func resumeFromBackground() async {
        isInBackground = false
        guard phase != .ended, !userInitiatedDisconnect else { return }

        if let prior = phaseBeforeSuspend, case .connected = transport.state {
            if await probeLiveness() {
                Self.log.info("resume: connection survived suspension — no reconnect")
                phaseBeforeSuspend = nil
                phase = prior
                // Output replays by itself; catch up on what changed while
                // frozen (layout, new/killed panes).
                await refreshStructure()
                return
            }
            Self.log.info("resume: probe failed — socket died during suspension")
        }
        phaseBeforeSuspend = nil
        scheduleReconnect()
    }

    // MARK: - Auto-reconnect

    /// What to do when the transport reports failure mid-session. A user
    /// tear-down and a pre-handshake failure stay failures; a blip during an
    /// established session becomes a quiet reconnect.
    private func handleUnexpectedFailure(message: String) {
        guard !userInitiatedDisconnect, phase != .ended else { return }
        // A loop is already running and owns recovery. Record the failure
        // though: an attempt that brought tmux up and THEN lost the socket
        // must not report success.
        guard reconnectTask == nil else {
            failedDuringReattach = true
            return
        }
        // Backgrounded, the channel is EXPECTED to die. Absorb it; the next
        // foreground retries.
        if isInBackground { return }
        Self.log.warning("tmux link lost (\(message, privacy: .public)) — reconnecting")
        scheduleReconnect()
    }

    /// Start a reconnect loop. Idempotent.
    private func scheduleReconnect() {
        guard reconnectTask == nil, !userInitiatedDisconnect,
              !isInBackground, phase != .ended else { return }
        reconnectAttempt = 0
        phase = .reconnecting
        reconnectTask = Task { [weak self] in await self?.runReconnectLoop() }
    }

    /// Reconnect with backoff until the session is back. Fast for the first
    /// attempts, then a steady 15s cadence FOREVER: the pre-merge product gave
    /// up after five and left a corpse screen, but a network or host blip can
    /// outlast any fixed budget, and that corpse screen is what the user
    /// experienced as "stuck reconnecting". Backgrounding cancels the loop.
    private func runReconnectLoop() async {
        defer { reconnectTask = nil }
        while !Task.isCancelled {
            if userInitiatedDisconnect || isInBackground || phase == .ended { return }
            reconnectAttempt += 1
            Self.log.info("auto-reconnect attempt \(self.reconnectAttempt)")
            if await reattach() {
                reconnectAttempt = 0
                return
            }
            if Task.isCancelled || userInitiatedDisconnect || isInBackground { return }
            let delay = reconnectAttempt >= 5 ? 15 : 1 << (reconnectAttempt - 1)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Bring a fresh transport up under the SAME link and put every pane back
    /// on the air.
    ///
    /// The pane sinks are deliberately NOT cleared. Each one belongs to a live
    /// `ControlModeTmuxTransport` holding this link weakly; replacing the link
    /// (which is what the shell used to do) left every one of them pointing at
    /// a dead object — output landed nowhere, keystrokes were dropped, and the
    /// reconnect still reported success. Reattaching in place keeps every pane
    /// wired to the connection that is now alive.
    private func reattach() async -> Bool {
        connected = false
        failedDuringReattach = false
        // Stop the pollers FIRST. Otherwise structure refreshes keep firing
        // into a half-built connection — typed into the raw login shell before
        // `tmux -CC` starts, with each orphaned continuation queueing in front
        // of the new session's real responses (off-by-N mismatch, timeout
        // storm, watchdog reconnect loop).
        refreshDebounce?.cancel()
        refreshDebounce = nil
        // The dead connection's protocol state is garbage: a truncated response
        // block and orphaned continuations would swallow the new stream's
        // notifications or steal its responses (the "input works but nothing
        // renders" zombie). Reset ON the parse queue so it runs after any stale
        // feedData already enqueued there.
        parseQueue.async { [control] in control.reset() }
        transport.disconnect()

        // `.adoptExisting`: the session's server-side geometry is whatever the
        // other attached clients have made it, and a reconnecting device must
        // not reshape their panes just by coming back.
        guard await bringUp(size: .adoptExisting, joiningGroup: false) else { return false }
        await reseedAllPanes()
        // `bringUp` succeeding only says the attach handshake worked. The seed
        // above is the heaviest burst this connection ever carries, and it is
        // exactly where a marginal link dies — leaving a session that looks
        // ready and never receives another byte.
        if failedDuringReattach {
            Self.log.warning("reattach: transport failed mid-attempt (likely during seed)")
            return false
        }
        // A new tmux client starts with no declared size.
        declareViewport(cols: declaredSize.cols, rows: declaredSize.rows)
        return true
    }

    /// After a reattach the reused surfaces still show the pre-drop screen —
    /// tmux does not repaint static content for a new control client, so
    /// anything that changed while we were gone would be missing until the
    /// program next redraws.
    ///
    /// Deliberately ONE SCREEN, unlike the fresh-bind seed: these surfaces are
    /// REUSED and already hold their history. A deep capture here would feed
    /// all of it a second time, and the clear+home below only clears the
    /// visible screen, not the scrollback above it.
    private func reseedAllPanes() async {
        for (pane, sink) in paneSinks {
            let lines = paneHeights[pane] ?? 50
            let response = await control.send(
                .capturePane(id: pane, lines: lines, escapes: true))
            guard !response.isError else { continue }
            let clean = TmuxParsers.stripControlModeChatter(response.output)
            guard !clean.isEmpty else { continue }
            var data = Data("\u{1b}[2J\u{1b}[H".utf8)
            data.append(Data(clean.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            sink(data)
        }
    }

    /// Two consecutive command timeouts: the session is dead in a way no
    /// transport layer reported.
    ///
    /// A transport can be half-dead at every layer that would notice — the
    /// socket still answers, but the remote shell is gone, so tmux never
    /// replies and the screen freezes while still reading "connected". This is
    /// the generic tripwire for that. The streak is only SPENT on an attempt
    /// that can actually run: clearing it before the guard threw it away
    /// whenever we happened to be mid-reconnect, so a wedged session needed
    /// four timeouts (~48s in the field) instead of two to be noticed.
    private func noteCommandTimeout() {
        commandTimeoutStreak += 1
        guard commandTimeoutStreak >= 2 else { return }
        guard phase == .ready, reconnectTask == nil,
              !isInBackground, !userInitiatedDisconnect else { return }
        commandTimeoutStreak = 0
        Self.log.warning("tmux stopped answering (2 consecutive timeouts) — forcing reconnect")
        scheduleReconnect()
    }

    /// User-driven retry from a connection-error banner.
    public func retry() {
        guard reconnectTask == nil else { return }
        userInitiatedDisconnect = false
        if phase == .ended { phase = .connecting }
        scheduleReconnect()
    }

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

    /// A pane's screen + scrollback as bytes a terminal surface can render.
    /// Bounded by `lines` because on a remote link every one of them is paid
    /// for (see `TmuxPaneModule.seedHistoryLines`).
    ///
    /// Everything below the `send` is the pre-merge product's seed path, which
    /// the daemon-era rewrite dropped. Each step is a fixed bug:
    ///
    /// * **Retry on error/empty.** `capture-pane` races the `select-window`
    ///   `%output` burst (timeout, or a parse that comes back empty); a lost
    ///   seed leaves the new surface blank until the TUI happens to repaint a
    ///   region — the "white screen, only updated parts show" on a window
    ///   switch.
    /// * **Strip chatter.** The response can carry notification lines the
    ///   parser handed back with it; fed to a surface they paint `%output %5
    ///   \033[…` over the pane (BUG-007, iOS-mostly).
    /// * **LF → CRLF.** `capture-pane -p -J` emits bare LF and the control-mode
    ///   parser joins response lines with `"\n"`, but a terminal needs CR to
    ///   return the carriage. Without it every seeded line is indented by the
    ///   length of the one above — the staircase.
    /// * **Cursor restore.** The capture returns the screen rows INCLUDING the
    ///   blank ones below a short prompt; fed as CRLF-terminated rows they park
    ///   the caret at the bottom of the captured region, not where tmux has it.
    ///   A freshly split pane then shows its prompt at the top and its caret at
    ///   the window bottom. Fields are SPACE-separated, never ";": ";" is
    ///   tmux's command separator and would split `display-message` in two.
    package func capture(pane: TmuxPaneID, lines: Int) async -> Data? {
        for _ in 0..<3 {
            let response = await control.send(
                .capturePane(id: pane, lines: lines, escapes: true))
            let text = response.isError
                ? "" : TmuxParsers.stripControlModeChatter(response.output)
            guard !response.isError, !text.isEmpty else {
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            var data = Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)

            let cursor = await control.send(
                .displayMessage(format: "#{cursor_y} #{cursor_x}", target: pane))
            let fields = cursor.isError ? [] : cursor.output
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            if fields.count == 2, let y = Int(fields[0]), let x = Int(fields[1]) {
                data.append(Data("\u{1b}[\(y + 1);\(x + 1)H".utf8))
            }
            return data
        }
        Self.log.warning("seed for pane \(pane.raw) gave up (error/empty ×3)")
        return nil
    }

    // MARK: - Commands (seam two's supply)

    /// Every command that matters goes through here rather than straight to
    /// `control`, so a response that never came feeds the tripwire. A timeout
    /// is reported as an ordinary `isError` response, which every call site
    /// treated as "return quietly" — which is exactly how a wedged session
    /// stayed on screen looking connected.
    @discardableResult
    package func send(_ command: TmuxCommand) async -> TmuxCommandResponse {
        let response = await control.send(command)
        if response.isError, response.output.hasPrefix("timeout") {
            noteCommandTimeout()
        } else if !response.isError {
            commandTimeoutStreak = 0
        }
        return response
    }

    // MARK: - Pane status (the detection tick's reading)

    /// Fresh per-pane detection inputs for every pane on the server: command,
    /// title, interaction flags, and the live working directory.
    ///
    /// Deliberately NOT part of the structure snapshot, exactly as on the
    /// daemon: every field here flaps without structural meaning (a starting
    /// `/bin/sh` reports `sh`, then `bash`; the cwd moves with every `cd`), and
    /// a flapping field inside change-detected structure would mint spurious
    /// revs. Two round trips because a path is free text and so is
    /// `pane_title` — two colon-bearing fields cannot share one positional
    /// line.
    public func paneStatuses() async -> [TmuxPaneStatus] {
        let listing = await control.send(.listPanes(allWindows: true))
        guard !listing.isError else { return [] }
        let panes = TmuxParsers.parsePaneList(listing.output)

        var paths: [TmuxPaneID: String] = [:]
        let pathListing = await control.send(.listPanePaths)
        if !pathListing.isError {
            for line in pathListing.output.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let id = TmuxPaneID(string: String(parts[0])) else { continue }
                paths[id] = String(parts[1])
            }
        }

        return panes.map { pane in
            TmuxPaneStatus(
                pane: pane.id,
                command: pane.currentCommand,
                title: pane.title,
                path: paths[pane.id],
                alternateOn: pane.alternateOn,
                mouseAny: pane.mouseAny,
                mouseSGR: pane.mouseSGR,
                inMode: pane.inMode)
        }
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

        case .sessionChanged(let session, let name):
            // This one IS about us — tmux only sends it for our own client.
            currentSessionID = session
            sessionName = name
            scheduleRefresh(immediate: false)

        case .sessionRenamed(let session, let name):
            // ONLY when tmux says the renamed session is ours. `sessionName`
            // is the target of `list-panes -t`, so adopting any rename on the
            // server pointed this client at somebody else's session and it
            // rendered — and operated on — the wrong panes. Modern tmux names
            // the session; the legacy bare-name form (session == nil) is a
            // label we can't attribute, so it changes nothing.
            if let session, session == currentSessionID, !name.isEmpty {
                sessionName = name
            }
            scheduleRefresh(immediate: false)

        case .clientDetached:
            // Another client left. Ours is still here — but the session's size
            // authority may have just changed hands, so re-read.
            scheduleRefresh(immediate: false)

        case .exit:
            // The control client is gone for good — the session was killed or
            // the server shut down. NOT a wire blip: reconnecting here would
            // run `new-session -A` and silently resurrect an empty session
            // under the same name instead of letting the window end.
            connected = false
            reconnectTask?.cancel()
            reconnectTask = nil
            phase = .ended
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
    public func refreshStructure() async {
        guard connected else { return }
        // In-flight guard. A drag-resize emits `%layout-change` continuously,
        // and each one used to launch its own untracked refresh — N concurrent
        // passes × three commands, stacked on the same control channel that
        // carries keystrokes.
        guard !refreshing else { refreshWanted = true; return }
        refreshing = true
        defer {
            refreshing = false
            if refreshWanted {
                refreshWanted = false
                scheduleRefresh(immediate: false)
            }
        }

        let windowsResponse = await send(.listWindows())
        guard !windowsResponse.isError else { return }
        let windows = TmuxParsers.parseWindowList(windowsResponse.output)
        // Under load (the repaint burst after a `select-window`, say) a command
        // response gets interleaved with `%output`, and the parser drops every
        // line it cannot read. Applying a SHORT window list silently truncates
        // the set — on a phone that is the window tab bar disappearing. Refuse
        // it and re-read.
        guard Self.parsedEveryLine(windows.count, windowsResponse.output) else {
            Self.log.warning("ignored raced list-windows parse — re-fetching")
            scheduleRefresh(immediate: false)
            return
        }

        // `-s` lists every pane in the session, so one round trip covers all
        // windows instead of one per window. Explicitly targeted at OUR
        // session, and `list-windows` above is the client's current session —
        // if those two ever disagree, every window pairs with zero panes and
        // the projection tears down every surface. `%session-changed` is what
        // keeps `sessionName` equal to the client's session.
        let panesResponse = await send(
            .listPanes(target: sessionName, sessionWide: true))
        guard !panesResponse.isError else { return }
        let panes = TmuxParsers.parsePaneList(panesResponse.output)
        // A live tmux session always has at least one pane, so an empty parse
        // is never real state — it is the same interleaving as above. Applying
        // it wipes the pane set, tearing down EVERY terminal surface (black
        // screen, broken responder chain, every keystroke a beep) until some
        // later refresh rebuilds them. Real teardown arrives as `%window-close`
        // / `%exit`, which do not come through here.
        guard !panes.isEmpty, Self.parsedEveryLine(panes.count, panesResponse.output) else {
            Self.log.warning("ignored raced list-panes parse — re-fetching")
            scheduleRefresh(immediate: false)
            return
        }
        // Heights for the reattach reseed, which captures ONE screen per pane.
        paneHeights = Dictionary(panes.map { ($0.id, $0.height) }, uniquingKeysWith: { a, _ in a })

        // Every session on the server, not just ours: the session strip, the
        // move-to-session menus and the window switcher all read the whole
        // picture. Only OUR session carries a structure — listing the others'
        // panes would be N more round trips for rows that render a name.
        var sessions: [TmuxSessionState] = []
        let sessionsResponse = await send(.listSessions)
        if !sessionsResponse.isError {
            for line in sessionsResponse.output.split(separator: "\n") {
                // Only `$id:name` lines are sessions. Pane output has been
                // observed mixed into a response body, and a noise line taken
                // for a session becomes a row in the switcher — and, worse, a
                // `switch-client` target when the current session is killed.
                guard line.hasPrefix("$") else { continue }
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = String(parts[1])
                let mine = name == sessionName
                sessions.append(TmuxSessionState(
                    id: String(parts[0]), name: name, attached: mine,
                    structure: mine ? Self.buildSnapshot(windows: windows, panes: panes)
                                    : TmuxStructureSnapshot(windows: [])))
            }
        }

        rev &+= 1
        let snapshot = Self.buildSnapshot(windows: windows, panes: panes)
        onState?(TmuxStructureState(
            rev: rev, target: target, session: sessionName, structure: snapshot,
            sessions: sessions.isEmpty ? nil : sessions))
    }

    /// A clean response parses every non-empty line. A shortfall means the body
    /// was interleaved with `%output`, so the result is partial, not smaller.
    private static func parsedEveryLine(_ parsed: Int, _ output: String) -> Bool {
        let lines = output.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return parsed == lines
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
