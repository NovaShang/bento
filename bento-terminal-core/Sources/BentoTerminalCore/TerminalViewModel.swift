import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.novashang.bento", category: "TerminalVM")

/// Optional file sink for the core package's `dlog`. Core logs default to
/// os_log only, which is invisible in the app's pullable `debug.log` — set
/// this once at app start (before any terminal work) to mirror every core
/// log line into the host app's file logger so real-device incidents can be
/// diagnosed from a single file pull.
public nonisolated(unsafe) var coreDlogFileSink: (@Sendable (String) -> Void)?

/// Package-local debug log (the app's global `dlog` lives in the iOS target).
func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
    coreDlogFileSink?(s)
}

// File diagnostics ordering surface-lifecycle vs feed events (os_log debug
// doesn't reliably reach `log show`). Off by default; opt in per-run with
// BENTO_DIAG=1 to trace to /tmp/bento-diag.log.
let _diagEnabled = ProcessInfo.processInfo.environment["BENTO_DIAG"] == "1"
let _diagLock = NSLock()
func DIAG(_ s: @autoclosure () -> String) {
    guard _diagEnabled else { return }
    _diagLock.lock(); defer { _diagLock.unlock() }
    let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, s())
    let url = URL(fileURLWithPath: "/tmp/bento-diag.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}

/// User's choice for how to start a session. (The name survives from the
/// tmux era for view compatibility; the cases now describe workspace
/// sessions, except `.noTmux` = the plain local-shell tab.)
public enum TmuxStartChoice: Hashable {
    /// Plain shell — no workspace session (mac local terminal tab).
    case noTmux
    /// Create or attach to a workspace session by name.
    case createOrAttach(name: String)
    /// Legacy "grouped with desktop" — attaches the target session directly.
    case shareWithDesktop(target: String)
    /// Build a session matching `spec` (working dir, agent command, layout),
    /// then attach.
    case createAgent(spec: AgentSpec)
}

/// High-level session phase. Distinct from low-level transport state.
public enum SessionPhase: Equatable {
    case sshConnecting       // transport handshake in progress
    case choosingSession     // transport up; user picking a session
    case starting            // applying choice
    case shellReady          // plain shell live (no workspace)
    case tmuxReady           // workspace session attached
    case suspended           // app backgrounded
    case ended
}

@MainActor
public final class TerminalViewModel: ObservableObject {
    @Published public var connectionState: TerminalConnectionState = .disconnected
    @Published public var errorMessage: String?
    @Published public var showError = false
    /// True while an auto-reconnect loop is in flight (after a drop, or on
    /// foreground resume). Drives a "Reconnecting…" banner so the UI is never
    /// silently frozen — distinct from `phase`, which churns through
    /// `.sshConnecting`/`.starting` during each attempt.
    @Published public var isReconnecting = false
    @Published public var paneViewModels: [PaneViewModel] = []
    @Published public var activePaneID: PaneID?
    /// The currently zoomed pane, or nil. When set, the tiled host shows only
    /// this pane filling the window.
    @Published public var zoomedPaneID: PaneID?
    /// Every pane in the attached session, refreshed together with
    /// `paneViewModels` (which holds the same set — each pane has a live
    /// content controller now that windows are gone).
    @Published public private(set) var sessionPanes: [Pane] = []
    /// The user-facing "Tiled | List" view mode — a pure presentation
    /// preference, remembered per session.
    @Published public internal(set) var sessionMode: SessionViewMode = .tiled
    /// The user's last explicit mode choice (UserDefaults, per session).
    var savedModePreference: SessionViewMode?
    /// One-shot latch for the initial mode-preference read.
    var modePreferenceLoaded = false
    @Published public var isTmuxReady = false

    /// Where we are in the session lifecycle.
    @Published public var phase: SessionPhase = .sshConnecting

    /// Sessions in the workspace store (the session switcher's list).
    @Published public var availableTmuxSessions: [String] = []
    @Published public var sessionsLoading: Bool = false

    /// Incremented on each state pipeline cycle to trigger SwiftUI re-render.
    @Published public var stateVersion: Int = 0

    /// Per-pane state for EVERY pane in the session, computed by the one
    /// detection pipeline in `updatePaneStates` — what the sidebar rows and
    /// tab dots read, so they can never disagree with the pane chrome.
    /// Repaints ride `stateVersion`.
    var paneStates: [PaneID: PaneState] = [:]

    /// Session-wide "done, unseen" flag per pane (an agent that finished its
    /// turn while unfocused → the green "done" check). Mirrors
    /// `PaneViewModel.agentFinishedUnseen`. Filled by `updatePaneStates`.
    var paneDoneUnseen: [PaneID: Bool] = [:]

    /// Live agent activity across the session's panes — drives the macOS
    /// toolbar's center summary ("N working · M waiting").
    @Published public var agentsWorking: Int = 0
    @Published public var agentsWaiting: Int = 0
    /// Agent panes that finished their turn while unfocused (the "done,
    /// unseen" state) — drives the session tab's status dot.
    @Published public var agentsDoneUnseen: Int = 0

    public let host: Host
    let transport: TerminalTransport
    /// The live transport, exposed for app-level features that need
    /// transport-specific capabilities. Core stays agnostic.
    public var activeTransport: TerminalTransport { transport }
    /// The workspace store backing this session's agents, or nil for the
    /// plain local-shell path (raw transport, no panes). App targets read
    /// this to pick pane content (agent chat vs terminal surface).
    public let workspace: AgentWorkspaceStore?
    /// Set on construction when this VM exists only so the UI can render an
    /// honest error (e.g. a direct-SSH host in an ACP-only build): connect()
    /// fails immediately with this message.
    public var unsupportedReason: String?
    public let stateDetection = StateDetectionService()
    let environment: TerminalEnvironment

    /// For non-workspace fallback: direct terminal data callback. Setting
    /// this replays the full history buffer so a re-bound TerminalView
    /// repaints scrollback instead of showing an empty screen.
    public nonisolated(unsafe) var onRawDataReceived: (@Sendable (Data) -> Void)? {
        didSet {
            guard let onRawDataReceived, !rawHistory.isEmpty else { return }
            onRawDataReceived(rawHistory)
        }
    }

    /// Rolling buffer of raw shell bytes (plain-shell mode). Capped. Marked
    /// nonisolated(unsafe) so the `onRawDataReceived` didSet (also
    /// nonisolated) can read it — all real access happens on MainActor.
    nonisolated(unsafe) private var rawHistory = Data()
    private static let maxRawHistoryBytes = 256 * 1024

    /// Push predicted keystrokes (Mosh-style local echo) to the surface as a
    /// preedit overlay. Set by the host wiring (plain-shell path only).
    public var onPredictionText: ((String) -> Void)?

    /// Predictive local echo for the raw path. Inert unless the feature flag
    /// is on; only ever touches an overlay, never the authoritative grid.
    private lazy var predictor: PredictiveEcho = {
        let p = PredictiveEcho(enabled: Self.predictiveEchoEnabled)
        p.render = { [weak self] text in self?.onPredictionText?(text) }
        return p
    }()

    /// Feature flag (Settings / UserDefaults). Off unless explicitly enabled.
    public nonisolated static var predictiveEchoEnabled: Bool {
        UserDefaults.standard.bool(forKey: "predictive_echo_enabled")
    }

    /// Whether a workspace session is attached (the panes are live).
    private(set) var attached = false

    /// Active workspace session name (kill/rename/switch target).
    @Published public internal(set) var activeTmuxSessionName: String?

    /// Identity token for the store listener — lets deinit (nonisolated)
    /// remove the registration without capturing self.
    private let listenerToken = NSObject()

    /// True while we're waiting on a scheduled auto-reconnect attempt.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// The surface's last reported grid (cols, rows). Used to start the shell
    /// at the rendered size so the PTY width always matches the surface.
    private var lastReportedSize: (cols: Int, rows: Int)?
    /// Set true by `disconnect()` / host deletion so we don't try to revive
    /// a session the user explicitly tore down.
    private var userInitiatedDisconnect = false
    /// True while the app is backgrounded (or transitioning there).
    private var isInBackground = false
    /// The live phase captured when the session was suspended. If the
    /// transport survives the suspension (probed on resume), the phase is
    /// restored directly — no reconnect.
    private var phaseBeforeSuspend: SessionPhase?

    private var statePollingTask: Task<Void, Never>?

    public init(host: Host, transport: TerminalTransport, environment: TerminalEnvironment,
                workspace: AgentWorkspaceStore? = nil) {
        self.host = host
        self.transport = transport
        self.environment = environment
        self.workspace = workspace
        setupCallbacks()
    }

    deinit {
        // The listener closure holds weak self; sweep the registration on the
        // main actor via the token (self is gone by the time the task runs).
        if let workspace {
            let token = listenerToken
            Task { @MainActor in workspace.removeListener(token) }
        }
    }

    private func setupCallbacks() {
        transport.onStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.connectionState = state
                if case .failed(let msg) = state {
                    self.handleUnexpectedFailure(message: msg)
                } else if case .connected = state {
                    // Successful (re)connect — clear the backoff counter.
                    self.reconnectAttempt = 0
                }
            }
        }

        transport.onDataReceived = { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                self.routeIncomingData(data)
            }
        }
    }

    /// Route a chunk of bytes from the raw transport to the terminal.
    /// (Workspace sessions have no byte stream — agents speak JSON-RPC
    /// through their own connections.)
    private func routeIncomingData(_ data: Data) {
        guard phase == .shellReady else { return }
        // Reconcile predictions against the echo BEFORE it renders, so a
        // confirmed char's overlay is retired as the real byte paints over it.
        predictor.didReceive(data)
        appendRawHistory(data)
        onRawDataReceived?(data)
    }

    private func appendRawHistory(_ data: Data) {
        rawHistory.append(data)
        let overflow = rawHistory.count - Self.maxRawHistoryBytes
        if overflow > 0 {
            rawHistory.removeSubrange(0..<overflow)
        }
    }

    // MARK: - Connect

    public func connect() async {
        userInitiatedDisconnect = false
        if let reason = unsupportedReason {
            errorMessage = reason
            showError = true
            phase = .ended
            return
        }
        // NOTE: do NOT cancel `reconnectTask` here. `connect()` can be called
        // from inside the reconnect loop; cancelling would kill the loop
        // mid-flight. The loop owns `reconnectTask`; user-initiated
        // tear-downs cancel it in `disconnect()`.
        rawHistory.removeAll(keepingCapacity: true)
        guard let startedSize = await bringUpTransport() else { return }

        if workspace == nil {
            // Plain shell: wait briefly for the prompt to settle, then
            // re-assert the surface's real grid (a resize that fired while
            // the transport was still connecting gets dropped).
            try? await Task.sleep(for: .milliseconds(500))
            if let s = lastReportedSize, s.cols != startedSize.cols || s.rows != startedSize.rows {
                dlog("post-connect resize to \(s.cols)x\(s.rows) (shell started at \(startedSize.cols)x\(startedSize.rows))")
                transport.resize(cols: s.cols, rows: s.rows)
            }
        }

        phase = .choosingSession
        await refreshTmuxSessions()
    }

    /// Bring the transport up and start the PTY at the rendered size. Shared
    /// by first connect and reattach. Returns the size the shell was started
    /// at, or nil if the transport failed to connect. (Workspace sessions use
    /// a NullTransport — instant, no PTY.)
    private func bringUpTransport() async -> (cols: Int, rows: Int)? {
        errorMessage = nil
        showError = false
        phase = .sshConnecting
        dlog("Connecting to \(self.host.hostname):\(self.host.port)")
        await transport.connect(host: host)

        guard case .connected = transport.state else {
            dlog("transport connect failed: \(String(describing: self.transport.state))")
            return nil
        }

        let screenSize = lastReportedSize ?? idealTerminalSize()
        dlog("startShell \(screenSize.cols)x\(screenSize.rows) (lastReported=\(String(describing: lastReportedSize)))")
        transport.startShell(cols: screenSize.cols, rows: screenSize.rows)
        return screenSize
    }

    /// Calculate ideal cols×rows to fill the screen. Used only for the
    /// initial PTY size (before the surface has laid out) and the
    /// user-triggered "reset client size" action.
    private func idealTerminalSize() -> (cols: Int, rows: Int) {
        environment.idealTerminalSize()
    }

    // MARK: - Session picker

    /// Refresh the session list from the workspace store.
    public func refreshTmuxSessions() async {
        guard !sessionsLoading else { return }
        sessionsLoading = true
        defer { sessionsLoading = false }
        guard let workspace else { return }   // plain shell: nothing to list
        availableTmuxSessions = workspace.sessionList.map(\.name)
    }

    /// Apply the user's session choice. Called from the session picker UI /
    /// the mac tab manager.
    public func applyTmuxChoice(_ choice: TmuxStartChoice) async {
        phase = .starting
        guard let workspace else {
            // Plain shell (the only raw-path choice): subsequent transport
            // data flows to the single-pane terminal. `clear` so the screen
            // starts fresh with a well-defined cursor.
            phase = .shellReady
            transport.write("clear\n")
            return
        }
        switch choice {
        case .noTmux:
            // Workspace-backed VMs have no raw shell; nothing to show.
            phase = .shellReady
        case .createOrAttach(let name):
            await attachWorkspaceSession(name)
        case .shareWithDesktop(let target):
            // Grouped twins are pointless without per-client viewports —
            // attach the target directly.
            await attachWorkspaceSession(target)
        case .createAgent(let spec):
            dlog("Creating agent session \(spec.sessionName) (\(spec.layout.paneCount) panes)")
            workspace.createAgentSession(spec)
            await attachWorkspaceSession(spec.sessionName)
        }
    }

    /// Attach this VM to a workspace session: ensure it exists, spawn its
    /// agent runtimes, subscribe to store events, publish the panes.
    private func attachWorkspaceSession(_ name: String) async {
        guard let workspace else { return }
        attached = true
        let canonical = workspace.ensureSession(name)
        activeTmuxSessionName = canonical
        workspace.ensureRuntimes(session: canonical)
        workspace.addListener(listenerToken) { [weak self] event in
            self?.handleWorkspaceEvent(event)
        }
        await refreshPanes()
        dlog("workspace ready: \(self.paneViewModels.count) panes in \(canonical)")
        isTmuxReady = true
        phase = .tmuxReady
        startStatePolling()
        await refreshTmuxSessions()
    }

    // MARK: - Store events

    private func handleWorkspaceEvent(_ event: AgentWorkspaceStore.Event) {
        switch event {
        case .structure(let session):
            guard session == activeTmuxSessionName else { return }
            // Panes added by another device (statekv adoption) need their
            // agent runtimes before the refresh lists them.
            workspace?.ensureRuntimes(session: session)
            Task { await refreshPanes() }
        case .geometry(let session, let layout):
            guard session == activeTmuxSessionName else { return }
            applyLayoutGeometry(layout)
            Task { await refreshPanes() }
        case .activity(let pane):
            guard let workspace,
                  workspace.sessionName(ofPane: pane) == activeTmuxSessionName else { return }
            updatePaneStates()
        case .sessionsChanged:
            availableTmuxSessions = workspace?.sessionList.map(\.name) ?? []
        }
    }

    // MARK: - Pane management

    public func refreshPanes() async {
        guard let workspace, let name = activeTmuxSessionName else { return }
        let panes = workspace.paneList(session: name)
        // The attached session vanished (killed here or on another device):
        // keep the last published state; the owning UI tears the tab down.
        guard !panes.isEmpty else { return }
        if sessionPanes != panes { sessionPanes = panes }
        updatePaneViewModels(panes)
        recomputeSessionMode()
    }

    /// Apply pure geometry from the layout tree to the existing panes,
    /// immediately and synchronously, so their surfaces resize before any
    /// repaint. New/removed panes are reconciled by `refreshPanes`.
    private func applyLayoutGeometry(_ layout: LayoutTree.Node) {
        let frames = LayoutTree.frames(of: layout)
        var changed = false
        for vm in paneViewModels {
            guard let f = frames[vm.paneID.raw] else { continue }
            var p = vm.pane
            guard p.width != f.w || p.height != f.h || p.x != f.x || p.y != f.y else { continue }
            p.width = f.w; p.height = f.h; p.x = f.x; p.y = f.y
            vm.updatePane(p)
            changed = true
        }
        if changed { onGeometryApplied?() }
    }

    /// Synchronous hook invoked right after new pane geometry is applied.
    /// The view layer sets this to re-tile its surfaces.
    public var onGeometryApplied: (() -> Void)?

    private func updatePaneViewModels(_ panes: [Pane]) {
        // Snapshot BEFORE updatePane mutates the reused instances, so the
        // no-change gate below compares against what was actually published.
        let oldVMs = paneViewModels
        let oldPanes = oldVMs.map(\.pane)

        var newViewModels: [PaneViewModel] = []
        var newPaneIDs: [PaneID] = []

        for pane in panes {
            if let existing = paneViewModels.first(where: { $0.paneID == pane.id }) {
                existing.updatePane(pane)
                if existing.isActive != pane.isActive { existing.isActive = pane.isActive }
                newViewModels.append(existing)
            } else {
                let vm = PaneViewModel(pane: pane, workspace: workspace)
                vm.isActive = pane.isActive
                newViewModels.append(vm)
                newPaneIDs.append(pane.id)
                DIAG("newVM \(pane.id) \(pane.width)x\(pane.height)")
            }
        }

        // Equality-gate the array publish: the 2s poll usually returns the
        // same panes with the same data, and every republish makes the hosts
        // re-run syncPanes/layout.
        let identical = newPaneIDs.isEmpty
            && newViewModels.count == oldVMs.count
            && zip(newViewModels, oldVMs).allSatisfy { $0 === $1 }
            && panes == oldPanes
        if !identical { paneViewModels = newViewModels }

        if !newPaneIDs.isEmpty {
            updatePaneStates()
        }

        if let active = panes.first(where: { $0.isActive }) {
            if activePaneID != active.id { activePaneID = active.id }
            let newZoom = active.isZoomed ? active.id : nil
            if zoomedPaneID != newZoom { zoomedPaneID = newZoom }
        } else {
            if zoomedPaneID != nil { zoomedPaneID = nil }
        }
    }

    // MARK: - Actions

    public func splitPane(horizontal: Bool) {
        guard let workspace, let name = activeTmuxSessionName else { return }
        guard let target = activePaneID?.raw ?? workspace.session(name)?.activePane else { return }
        _ = workspace.splitPane(session: name, target: target, horizontal: horizontal,
                                cwd: nil, command: nil)
    }

    public func selectPane(_ paneID: PaneID) {
        guard attached else { return }
        workspace?.selectPane(paneID.raw)
        activePaneID = paneID
        for vm in paneViewModels {
            vm.isActive = (vm.paneID == paneID)
            // Focusing a pane = seeing it → clear the "done, unseen" badge.
            if vm.paneID == paneID, vm.agentFinishedUnseen {
                vm.agentFinishedUnseen = false
            }
        }
    }

    public func resizePaneBy(_ paneID: PaneID, direction: String, amount: Int) {
        workspace?.resizePane(paneID.raw, direction: direction, amount: amount)
    }

    public func toggleZoom(_ paneID: PaneID) {
        workspace?.toggleZoom(paneID.raw)
    }

    public func closePane(_ paneID: PaneID) {
        workspace?.killPane(paneID.raw)
    }

    /// Swap a pane with its previous/next neighbor in layout order. Content
    /// follows pane IDs, so no repaint is needed beyond the re-tile.
    public func swapPane(_ paneID: PaneID, up: Bool) {
        guard attached else { return }
        workspace?.swapPane(paneID.raw, up: up)
    }

    /// Swap two specific panes (drag a pane's title bar onto another pane's
    /// CENTER drop zone).
    public func swapPanes(_ source: PaneID, with destination: PaneID) {
        guard attached, source != destination else { return }
        workspace?.swapPanes(source.raw, destination.raw)
    }

    /// Dock `source` against one edge of `target` (drag onto an EDGE drop
    /// zone): the target's cell splits along that axis and the dragged pane
    /// lands in the new half, focused.
    public func movePane(_ source: PaneID, splitting target: PaneID,
                         horizontal: Bool, before: Bool) {
        guard attached, source != target else { return }
        workspace?.dockPane(source.raw, at: target.raw, horizontal: horizontal, before: before)
    }

    /// Force a pane's detection profile (pane menu → Change Profile); nil =
    /// auto-detect. (Terminal-era knob; inert for chat panes.)
    public func setPaneProfile(_ profileID: String?, for paneID: PaneID) {
        stateDetection.setProfileOverride(profileID, for: paneID)
    }

    public func paneProfile(for paneID: PaneID) -> String? {
        stateDetection.profileOverride(for: paneID)
    }

    /// Rename a pane (shown in the pane title bar / sidebar rows).
    public func renamePane(_ paneID: PaneID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspace?.renamePane(paneID.raw, to: trimmed)
    }

    /// Point this VM at another workspace session (the session switcher).
    public func switchSession(_ name: String) {
        guard let workspace, attached, name != activeTmuxSessionName,
              workspace.session(name) != nil else { return }
        activeTmuxSessionName = name
        workspace.ensureRuntimes(session: name)
        Task {
            await refreshPanes()
            updatePaneStates()
        }
    }

    /// Rename the attached session (the toolbar's "Rename Session…").
    public func renameSession(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace, attached, !trimmed.isEmpty,
              let current = activeTmuxSessionName, trimmed != current else { return }
        workspace.renameSession(current, to: trimmed)
        // The store refuses colliding names; adopt only what actually took.
        activeTmuxSessionName = workspace.session(trimmed) != nil ? trimmed : current
        Task { await refreshTmuxSessions() }
    }

    /// Open a fresh pane in the session (largest-cell insertion). The name
    /// survives from the window era — every "window" is a pane now.
    public func newWindow(name: String? = nil) {
        guard let workspace, let session = activeTmuxSessionName else { return }
        _ = workspace.newPane(session: session, cwd: nil, command: nil)
    }

    // MARK: - Direct input

    public func sendData(_ data: Data) {
        if attached, let activePaneID,
           let paneVM = paneViewModels.first(where: { $0.paneID == activePaneID }) {
            paneVM.sendInput(data)
        } else {
            predictor.willSend(data)   // draw the prediction; doesn't alter what's sent
            transport.write(data)
        }
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendData(data)
    }

    public func resizeTerminal(cols: Int, rows: Int) {
        // Remember the surface's authoritative grid so a (re)connect can
        // start the shell at the SAME size.
        if cols > 0, rows > 0 { lastReportedSize = (cols, rows) }
        transport.resize(cols: cols, rows: rows)
    }

    /// Resize the session's canvas (the layout tree renormalizes). Used when
    /// the visible area changes so the tiling fills exactly the viewport.
    public func resizeTmuxClient(cols: Int, rows: Int) {
        guard attached, let name = activeTmuxSessionName else { return }
        workspace?.resizeCanvas(session: name, cols: cols, rows: rows)
    }

    /// User-triggered: resize the session canvas to fit the current device
    /// viewport at the native cell size.
    public func resetTmuxClientToDeviceSize() {
        guard attached else { return }
        let (cols, rows) = idealTerminalSize()
        resizeTmuxClient(cols: cols, rows: rows)
    }

    public func killSession() {
        if let name = activeTmuxSessionName {
            workspace?.killSession(name)
        }
        disconnect()
    }

    public func disconnect() {
        userInitiatedDisconnect = true
        isReconnecting = false
        reconnectTask?.cancel()
        reconnectTask = nil
        statePollingTask?.cancel()
        statePollingTask = nil
        workspace?.removeListener(listenerToken)
        transport.disconnect()
        let priorName = activeTmuxSessionName ?? ""
        attached = false
        isTmuxReady = false
        phase = .ended
        paneViewModels = []
        rawHistory.removeAll(keepingCapacity: false)
        environment.onSessionUpdate(host.id, priorName, 0, "")
    }

    /// Called when the app enters background. Cancel the polling loop and
    /// mark the phase; the daemon keeps the agents alive — re-sync on resume.
    public func suspendForBackground() {
        isInBackground = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isReconnecting = false
        statePollingTask?.cancel()
        statePollingTask = nil
        switch phase {
        case .tmuxReady, .shellReady:
            phaseBeforeSuspend = phase
            phase = .suspended
        case .starting, .sshConnecting, .choosingSession:
            phaseBeforeSuspend = nil
            phase = .suspended
        case .suspended, .ended:
            break
        }
    }

    /// Called when the app returns to foreground. Revive the session if the
    /// live connection is gone.
    public func resumeFromBackground() async {
        isInBackground = false
        switch phase {
        case .tmuxReady, .shellReady, .starting, .choosingSession:
            return
        case .suspended, .ended, .sshConnecting:
            break
        }
        // Fast path: the transport usually SURVIVES a background suspension.
        if phase == .suspended, let prior = phaseBeforeSuspend,
           case .connected = transport.state {
            if await transport.probeLiveness() {
                dlog("resume: connection survived suspension — restoring \(String(describing: prior)), no reconnect")
                phaseBeforeSuspend = nil
                phase = prior
                if prior == .tmuxReady {
                    startStatePolling()
                    // Catch up on anything that changed while frozen.
                    Task {
                        await self.workspace?.syncWithDaemon()
                        await self.refreshPanes()
                        self.updatePaneStates()
                    }
                }
                return
            }
            dlog("resume: probe failed — transport died during suspension")
        }
        phaseBeforeSuspend = nil
        dlog("Resuming session for \(self.host.hostname) (\(String(describing: self.phase)) → reconnect)")
        scheduleReconnect()
    }

    /// Bring the session back after a drop: reconnect the transport and, for
    /// workspace sessions, re-sync the store with the daemon and re-attach.
    /// Returns whether the session came back up.
    @discardableResult
    private func reattachExistingSession() async -> Bool {
        attached = false
        isTmuxReady = false
        statePollingTask?.cancel()
        statePollingTask = nil

        guard await bringUpTransport() != nil else { return false }

        guard let workspace else {
            // Plain shell: the fresh shell streams to the surface once the
            // phase is live again.
            phase = .shellReady
            return true
        }
        guard let name = activeTmuxSessionName else {
            phase = .choosingSession
            return true
        }
        await workspace.syncWithDaemon()
        await attachWorkspaceSession(name)
        return isTmuxReady
    }

    // MARK: - Auto-reconnect

    /// Decide what to do when the transport reports `.failed` mid-session.
    private func handleUnexpectedFailure(message: String) {
        guard !userInitiatedDisconnect else { return }
        guard !isReconnecting else { return }
        if isInBackground || phase == .suspended {
            reconnectTask?.cancel()
            reconnectTask = nil
            phase = .suspended
            return
        }
        let recoverable: Bool
        switch phase {
        case .tmuxReady, .shellReady, .starting:
            recoverable = true
        case .sshConnecting, .choosingSession, .suspended, .ended:
            recoverable = false
        }
        guard recoverable else {
            errorMessage = message
            showError = true
            return
        }
        scheduleReconnect()
    }

    /// Start a reconnect loop. Idempotent: a no-op while one is already
    /// running, backgrounded, or after a user-initiated tear-down.
    private func scheduleReconnect() {
        guard reconnectTask == nil, !userInitiatedDisconnect, !isInBackground else { return }
        reconnectAttempt = 0
        isReconnecting = true
        errorMessage = nil
        showError = false
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    /// Reconnect with exponential backoff until the session is back.
    private func runReconnectLoop() async {
        defer {
            isReconnecting = false
            reconnectTask = nil
        }
        while !Task.isCancelled {
            if userInitiatedDisconnect || isInBackground { return }
            reconnectAttempt += 1
            dlog("auto-reconnect attempt \(self.reconnectAttempt)")
            if await reattachExistingSession() {
                reconnectAttempt = 0
                return
            }
            if Task.isCancelled || userInitiatedDisconnect || isInBackground { return }
            // Fast backoff (1/2/4/8s) for the first attempts, then a steady
            // 15s cadence forever. Backgrounding cancels the loop.
            let delaySec = reconnectAttempt >= 5 ? 15 : 1 << (reconnectAttempt - 1)
            dlog("reconnect failed; retrying in \(delaySec)s")
            try? await Task.sleep(for: .seconds(delaySec))
        }
    }

    /// User-driven retry from the connection-error alert.
    public func retry() {
        guard !isReconnecting else { return }
        userInitiatedDisconnect = false
        scheduleReconnect()
    }

    // MARK: - State pipeline

    private func startStatePolling() {
        // Idempotent: never stack a second poller. Store events drive the
        // pipeline; the poll is a cheap safety net that also refreshes pane
        // metadata (titles follow live runtime titles).
        statePollingTask?.cancel()
        statePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { break }
                await self.refreshPanes()
                self.updatePaneStates()
            }
        }
    }

    private func updatePaneStates() {
        var changed = false
        var awaitingCount = 0
        var sawNewAwaiting = false
        var latestPrompt = ""
        var agentWorking = 0
        var agentWaiting = 0
        var agentDoneUnseen = 0

        var newStates: [PaneID: PaneState] = [:]
        var newDone: [PaneID: Bool] = [:]

        for paneVM in paneViewModels {
            let current = paneVM.paneState
            let (newState, isAgent) = classifyPane(id: paneVM.paneID, current: current)
            newStates[paneVM.paneID] = newState

            if paneVM.paneState != newState {
                // Transition INTO awaiting — fire haptic + snippet. The
                // pending permission line IS the prompt.
                if case .awaitingInput = newState {
                    sawNewAwaiting = true
                    let snippet = workspace?.runtime(forPane: paneVM.paneID.raw)?.previewLine ?? ""
                    if !snippet.isEmpty { latestPrompt = snippet }
                }
                paneVM.paneState = newState
                changed = true
            }

            if updateSeen(paneVM, from: current, to: newState, isAgent: isAgent) {
                changed = true
            }
            newDone[paneVM.paneID] = paneVM.agentFinishedUnseen

            if case .awaitingInput = paneVM.paneState {
                awaitingCount += 1
            }

            // Tally agent activity for the toolbar's center summary.
            if isAgent {
                if paneVM.agentFinishedUnseen { agentDoneUnseen += 1 }
                switch paneVM.paneState {
                case .working:       agentWorking += 1
                case .awaitingInput: agentWaiting += 1
                case .idle:          break
                }
            }
        }
        if paneStates != newStates { changed = true }
        paneStates = newStates
        paneDoneUnseen = newDone

        if changed {
            stateVersion += 1
        }
        if agentsWorking != agentWorking { agentsWorking = agentWorking }
        if agentsWaiting != agentWaiting { agentsWaiting = agentWaiting }
        if agentsDoneUnseen != agentDoneUnseen { agentsDoneUnseen = agentDoneUnseen }
        if sawNewAwaiting {
            environment.onAwaitingTriggered()
        }
        // Fan into the session manager so the aggregate Live Activity
        // recomputes across all live sessions.
        environment.onSessionUpdate(host.id, activeTmuxSessionName ?? "", awaitingCount, latestPrompt)
    }

    /// THE per-pane state judgment — exact, read straight off the pane's
    /// agent-turn lifecycle (no screen scraping). Every workspace pane is an
    /// agent pane.
    private func classifyPane(id: PaneID, current: PaneState) -> (state: PaneState, isAgent: Bool) {
        guard let workspace else { return (current, false) }
        guard let runtime = workspace.runtime(forPane: id.raw) else {
            return (.working, true)   // record exists, agent still spawning
        }
        if runtime.pendingPermission != nil || runtime.phase == .authRequired {
            return (.awaitingInput(profile: runtime.preset.id), true)
        }
        if runtime.isTurnActive || runtime.phase == .starting {
            return (.working, true)
        }
        return (.idle, true)
    }

    /// Maintain the "done, unseen" flag. An agent pane that transitions into
    /// .idle while unfocused becomes done(unseen); focusing it or leaving
    /// idle clears it. Returns true if the flag changed.
    @discardableResult
    private func updateSeen(_ paneVM: PaneViewModel, from current: PaneState,
                            to newState: PaneState, isAgent: Bool) -> Bool {
        let want = Self.doneUnseen(isAgent: isAgent, isFocused: paneVM.isActive,
                                   current: current, newState: newState,
                                   prev: paneVM.agentFinishedUnseen)
        guard paneVM.agentFinishedUnseen != want else { return false }
        paneVM.agentFinishedUnseen = want
        return true
    }

    /// Pure "done, unseen" transition: an agent pane that goes idle while
    /// UNFOCUSED becomes done; staying idle keeps the memory; focusing it or
    /// leaving idle clears it.
    static func doneUnseen(isAgent: Bool, isFocused: Bool, current: PaneState,
                           newState: PaneState, prev: Bool) -> Bool {
        guard isAgent, isIdle(newState), !isFocused else { return false }
        return isIdle(current) ? prev : true
    }

    private static func isIdle(_ s: PaneState) -> Bool {
        if case .idle = s { return true }
        return false
    }
}
