// Ported from frozen TerminalViewModel.swift @ 8fa54b6^; data layer swapped, UI verbatim.
//
// The API surface the frozen shell consumes, re-implemented on the trunk
// spine: structure is a READING of the daemon's tmux mirror
// (TermDaemonLink → TmuxStructureState → this VM's session row), mutations
// are structure verbs (DaemonAuthority; the next mirror snapshot is the
// answer, never an optimistic local tree), pane content rides
// TmuxPaneRuntime byte pipes registered in TermShell.store, and sizing is
// the daemon's session-size authority (viewport declarations +
// setSizePolicy). Where the frozen VM did client-side things the daemon now
// owns, this adapter translates — the shell files stay untouched in behavior.

import Foundation
import SwiftUI
import os
import BentoFoundation
import BentoLink
import BentoTerminalPane
import BentoTmuxPane
import BentoUI
import BentoWorkbench

private let log = Logger(subsystem: "com.novashang.bento", category: "TerminalVM")

/// Package-local debug log (kept from the frozen core so ported call sites read
/// unchanged).
func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
}

/// File diagnostics ordering surface-lifecycle vs seed-feed events (os_log
/// debug doesn't reliably reach `log show`). Off by default; opt in per-run
/// with BENTO_DIAG=1 to trace to /tmp/bento-diag.log.
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

/// Shared logger for the path-preview plumbing (the frozen core's lived in
/// the file-preview sources; the kit keeps its own internal twin).
let pathPreviewLog = Logger(subsystem: "com.novashang.bento", category: "PathPreview")

/// User's choice for how to start a session on the host.
public enum TmuxStartChoice: Hashable {
    /// Don't use tmux — plain shell.
    case noTmux
    /// Create or attach to a session by name (no grouping).
    case createOrAttach(name: String)
    /// Create a grouped session that mirrors `target` (shared with desktop).
    /// FLAGGED: tmux session GROUPING has no daemon verb — kept for API
    /// parity (nothing on the Mac shell offers it); lands as a plain ensure
    /// of the frozen "<target>-mobile" name.
    case shareWithDesktop(target: String)
    /// Spin up a tmux session matching `spec` (working dir, agent command,
    /// layout), then attach.
    case createAgent(spec: AgentSpec)
}

/// High-level session phase. The SSH-era cases collapsed with the transport:
/// the daemon link either is up or isn't.
public enum SessionPhase: Equatable {
    case starting            // applying the start choice (ensure in flight)
    case shellReady          // non-tmux: plain daemon-pty shell live
    case tmuxReady           // tmux structure mirror live
    case ended
}

/// One tmux window as this session's mirror row lists it. `id` is the tmux
/// window INDEX (the mirror carries no `@id`; the index is what
/// `select-window -t` takes and what every label shows).
public struct TmuxWindowID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "\(raw)" }
}

public struct TmuxWindow: Identifiable, Equatable, Sendable {
    public let id: TmuxWindowID
    public let index: Int?
    public var name: String
    public var layout: String
    public var isActive: Bool
}

/// One pane as this session's mirror row lists it — the reading the frozen
/// `list-panes -s` built. The geometry comes from the structure mirror; the
/// four INTERACTION-mode flags below deliberately do not (they flap with
/// every TUI that starts or exits and would mint a mirror rev per flap), so
/// they ride the `tmuxpanes` poll and are merged in by
/// `TerminalViewModel.adoptPaneModes`.
public struct Pane: Identifiable, Equatable, Sendable {
    public let id: TmuxPaneID
    public var windowID: TmuxWindowID?
    public var inActiveWindow: Bool
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var isActive: Bool
    public var isZoomed: Bool
    public var title: String?
    public var currentCommand: String?
    public var alternateOn: Bool = false
    public var mouseAny: Bool = false
    public var mouseSGR: Bool = false
    public var inMode: Bool = false

    /// The four polled flags as one value, so a mirror push can carry the
    /// last poll's reading forward instead of resetting the pane to "plain
    /// shell" every time the geometry changes.
    struct InteractionMode: Equatable, Sendable {
        var alternateOn = false
        var mouseAny = false
        var mouseSGR = false
        var inMode = false
    }

    var interactionMode: InteractionMode {
        get { .init(alternateOn: alternateOn, mouseAny: mouseAny,
                    mouseSGR: mouseSGR, inMode: inMode) }
        set {
            alternateOn = newValue.alternateOn
            mouseAny = newValue.mouseAny
            mouseSGR = newValue.mouseSGR
            inMode = newValue.inMode
        }
    }
}

/// App-level seams the frozen core took from its host app: the initial grid
/// estimate and the awaiting-notification fan-out.
public struct TerminalEnvironment {
    public var idealTerminalSize: () -> (cols: Int, rows: Int)
    public var onSessionUpdate: (UUID, String, Int, String) -> Void
    public var onAwaitingTriggered: () -> Void

    public init(idealTerminalSize: @escaping () -> (cols: Int, rows: Int) = { (120, 30) },
                onSessionUpdate: @escaping (UUID, String, Int, String) -> Void = { _, _, _, _ in },
                onAwaitingTriggered: @escaping () -> Void = {}) {
        self.idealTerminalSize = idealTerminalSize
        self.onSessionUpdate = onSessionUpdate
        self.onAwaitingTriggered = onAwaitingTriggered
    }
}

@MainActor
public final class TerminalViewModel: ObservableObject {
    @Published public var errorMessage: String?
    @Published public var showError = false
    @Published public var paneViewModels: [PaneViewModel] = []
    @Published public var activePaneID: TmuxPaneID?
    /// The currently zoomed pane (tmux `window_zoomed_flag`), or nil. When set,
    /// the tiled host shows only this pane filling the window.
    @Published public var zoomedPaneID: TmuxPaneID?
    @Published public var windows: [TmuxWindow] = []
    /// Every pane in the session across ALL windows, refreshed together with
    /// `paneViewModels`. Powers the hierarchical structure model: window list
    /// items, per-window agent status, and the spread/merge structure ops.
    /// `paneViewModels` stays scoped to the current window (only its panes
    /// have live surfaces).
    @Published public private(set) var sessionPanes: [Pane] = []
    /// The user-facing "Parallel | Focus" state, recomputed from structure on
    /// every mirror push. Degenerate (1×1) sessions present as Tiled unless
    /// the user explicitly chose List; mixed external structures read as
    /// Tiled. See TerminalViewModel+Structure.swift.
    @Published public internal(set) var sessionMode: TmuxSessionMode = .tiled
    /// The user's last explicit mode choice. The frozen product remembered it
    /// server-side in the `@bento_mode` tmux option; the daemon has no
    /// set-option verb yet (flagged), so it is remembered per session name in
    /// UserDefaults — one device's memory instead of every device's.
    var savedModePreference: TmuxSessionMode?
    /// The session's current window (drives the active tab highlight).
    @Published public var activeWindowID: TmuxWindowID?
    /// Who governs the tmux session's size. Held by the DAEMON's session-size
    /// authority (mirror `sizing` block) and adopted from every push, so two
    /// devices sharing a session agree instead of overwriting each other.
    @Published public var sizingMode: TerminalSizingMode = .tracking
    /// The device owning a `.thisDevice` session's size, nil under the
    /// client-derived policies.
    @Published public var sizingOwner: TmuxSizingOwner?
    /// The last grid this device measured for itself, recorded even when the
    /// policy forbids pushing it — claiming ownership later re-declares it.
    var lastTmuxClientSize: (cols: Int, rows: Int)?
    /// Dedup + settle gate in front of every client-size declaration.
    var viewportGate = ViewportDeclarationGate()

    /// True when this device is the size owner. The daemon keys ownership by
    /// the declaring STREAM; the mirror carries the owner's display label, so
    /// the honest client-side reading is label equality.
    public var sizingOwnerIsMe: Bool {
        guard let owner = sizingOwner else { return false }
        return owner.label == BentoDeviceLabel.current
    }
    @Published public var isTmuxReady = false

    /// Where we are in the session lifecycle.
    @Published public var phase: SessionPhase = .starting

    /// Sessions on the server (the mirror's session list).
    @Published public var availableTmuxSessions: [String] = []
    @Published public var sessionsLoading: Bool = false

    /// Incremented on each state poll cycle to trigger SwiftUI re-render
    @Published public var stateVersion: Int = 0

    /// Per-pane state for EVERY pane in the session (all windows), computed by
    /// the one detection pipeline in `updatePaneStates`. Current-window panes
    /// mirror their PaneViewModel's `paneState`; background-window panes are
    /// classified the same way. This is what `windowStatus` aggregates, so the
    /// List sidebar/tabs judge a window exactly like the Tiled pane chrome
    /// judges a pane. Repaints ride `stateVersion`.
    var paneStates: [TmuxPaneID: PaneState] = [:]

    /// Session-wide "done, unseen" flag per pane (an agent that finished its
    /// turn while its window was unfocused → the green "done" check).
    var paneDoneUnseen: [TmuxPaneID: Bool] = [:]

    /// Live agent activity across the current window's panes — drives the
    /// toolbar's dots.
    @Published public var agentsWorking: Int = 0
    @Published public var agentsWaiting: Int = 0
    @Published public var agentsDoneUnseen: Int = 0

    public let stateDetection = StateDetectionService()
    let environment: TerminalEnvironment
    /// Stable identity for the environment's session-update fan-out (the
    /// frozen host.id).
    let vmID = UUID()

    /// The store slot this VM's projection lands in (WorkspaceEntry.id).
    let entryID: Int
    private static var nextEntryID = 1

    /// Plain (no-tmux) tab: the daemon-pty command override (nil = login shell).
    private let plainCommand: [String]?

    /// For non-tmux fallback: direct terminal data callback. Setting this
    /// replays the full history buffer so a re-bound TerminalView repaints
    /// scrollback instead of showing an empty screen until the next byte.
    public nonisolated(unsafe) var onRawDataReceived: (@Sendable (Data) -> Void)? {
        didSet {
            guard let onRawDataReceived else { return }
            let replay = rawHistoryLock.withLock { $0 }
            guard !replay.isEmpty else { return }
            onRawDataReceived(replay)
        }
    }

    /// Rolling buffer of raw shell bytes (non-tmux mode). Capped.
    private nonisolated let rawHistoryLock = OSAllocatedUnfairLock(initialState: Data())
    private static let maxRawHistoryBytes = 256 * 1024

    /// Push predicted keystrokes (Mosh-style local echo) to the surface as a
    /// preedit overlay. Raw/no-tmux path only.
    public var onPredictionText: ((String) -> Void)?

    /// Predictive local echo for the raw path. Inert unless the feature flag is
    /// on; only ever touches an overlay, never the authoritative grid.
    private lazy var predictor: PredictiveEcho = {
        let p = PredictiveEcho(enabled: Self.predictiveEchoEnabled)
        p.render = { [weak self] text in self?.onPredictionText?(text) }
        return p
    }()

    /// Feature flag (Settings / UserDefaults). Off unless explicitly enabled.
    public nonisolated static var predictiveEchoEnabled: Bool {
        UserDefaults.standard.bool(forKey: "predictive_echo_enabled")
    }

    /// Whether this VM drives a tmux session (vs the plain daemon-pty tab).
    private(set) var usingTmux = false

    /// Active tmux session name (used for kill-session etc).
    @Published public private(set) var activeTmuxSessionName: String?
    /// The session's rename-stable tmux id ("$N"), learned from the mirror —
    /// how this VM keeps following its session across renames.
    private(set) var tmuxSessionID: String?

    /// Synchronous hook invoked right after new pane geometry is applied,
    /// before subsequent repaint output is processed. The view layer sets
    /// this to re-tile its surfaces.
    public var onGeometryApplied: (() -> Void)?

    private var statePollingTask: Task<Void, Never>?
    /// Rule-engine judge for background-window panes (no runtime, so no
    /// per-pane detection service to lean on): command/title/screen are the
    /// whole evidence there.
    private let backgroundDetection = StateDetectionService()
    /// One-shot latch for the initial mode-preference read.
    var modePreferenceLoaded = false

    let link = TermDaemonLink.shared
    let store = TermShell.store

    // MARK: - Plain (no-tmux) pty state

    /// The dedicated transport of a plain tab's daemon-hosted pty (one per
    /// tab — a stream binds to at most one instance daemon-side).
    private var ptyTransport: AcpHostTransport?
    private var ptyAgentID: String?

    public init(command: [String]? = nil, environment: TerminalEnvironment) {
        self.plainCommand = command
        self.environment = environment
        self.entryID = Self.nextEntryID
        Self.nextEntryID += 1
        TermShell.installPaneModule()
        store.addListener(self) { [weak self] event in self?.handleStoreEvent(event) }
    }

    // MARK: - Connect

    /// Bring the daemon link up. The session itself starts in
    /// `applyTmuxChoice` — the frozen split (connect → choose) is preserved
    /// so the shell's call sites read unchanged.
    public func connect() async {
        errorMessage = nil
        showError = false
        phase = .starting
        do {
            try await link.start()
        } catch {
            dlog("daemon link connect failed: \(error)")
            errorMessage = String(describing: error)
            showError = true
        }
    }

    /// Refresh the server's session list from the mirror.
    public func refreshTmuxSessions() async {
        guard !sessionsLoading else { return }
        sessionsLoading = true
        defer { sessionsLoading = false }
        let names = link.sessions.map(\.name)
        if availableTmuxSessions != names { availableTmuxSessions = names }
    }

    /// Apply the user's session choice. Called from the session window setup.
    public func applyTmuxChoice(_ choice: TmuxStartChoice) async {
        phase = .starting
        switch choice {
        case .noTmux:
            await startPlainShell()
        case .createOrAttach(let name):
            await launchTmux(sessionName: name)
        case .shareWithDesktop(let target):
            await launchTmux(sessionName: "\(target)-mobile")
        case .createAgent(let spec):
            dlog("Creating agent session \(spec.sessionName) (\(spec.layout.paneCount) panes)")
            await createAgentSession(spec)
        }
    }

    /// Ensure + attach the daemon's control client to this session. The
    /// frozen `tmux -CC new-session -A` in one verb.
    private func launchTmux(sessionName: String) async {
        usingTmux = true
        activeTmuxSessionName = sessionName
        register()
        do {
            try await link.ensure(session: sessionName)
        } catch {
            dlog("ensure \(sessionName) failed: \(error)")
            errorMessage = String(describing: error)
            showError = true
            phase = .ended
            return
        }
        isTmuxReady = true
        phase = .tmuxReady
        startStatePolling()
        await refreshTmuxSessions()
    }

    /// The agent wizard's session: create with the working directory, attach,
    /// build the extra panes (each running the agent command), and start the
    /// agent in the first pane. The frozen product seeded pane 1 on the -CC
    /// launch line; the daemon's createSession verb carries cwd but no
    /// command (flagged), so pane 1's agent is typed in over the byte pipe —
    /// the same keystrokes a user would send.
    private func createAgentSession(_ spec: AgentSpec) async {
        usingTmux = true
        activeTmuxSessionName = spec.sessionName
        register()
        do {
            if link.sessions.first(where: { $0.name == spec.sessionName }) == nil {
                _ = try await link.applyAwait(.createSession(
                    name: spec.sessionName, cwd: spec.workingDir.isEmpty ? nil : spec.workingDir))
            }
            try await link.ensure(session: spec.sessionName)
        } catch {
            dlog("createAgent: session setup failed: \(error)")
            errorMessage = String(describing: error)
            showError = true
            phase = .ended
            return
        }
        isTmuxReady = true
        phase = .tmuxReady
        startStatePolling()

        let program = spec.agentCommand.isEmpty ? nil : spec.agentCommand
        let firstPane = sessionPanes.first?.id
        let extraPanes = max(spec.layout.paneCount - 1, 0)
        if let target = firstPane, extraPanes > 0 {
            for i in 0..<extraPanes {
                do {
                    _ = try await link.applyAwait(.splitPane(
                        session: spec.sessionName, target: target.raw, horizontal: true,
                        cwd: spec.workingDir.isEmpty ? nil : spec.workingDir,
                        command: program))
                } catch {
                    dlog("createAgent: split \(i + 1)/\(extraPanes) failed: \(error)")
                }
            }
            // Named layouts have no daemon verb yet (flagged);
            // `applyTiled` covers the grid case, the split chain the rest.
            if spec.layout.tmuxLayoutName == "tiled" {
                _ = try? await link.applyAwait(.applyTiled(session: spec.sessionName))
            }
        }
        if let program, let first = firstPane {
            // Give the first pane's shell a beat to come up, then run the agent.
            try? await Task.sleep(for: .milliseconds(600))
            (store.runtime(forPane: first.raw) as? TmuxPaneRuntime)?.send(program)
        }
        await refreshTmuxSessions()
    }

    private func register() {
        link.register(self) { [weak self] state in self?.adopt(state) }
    }

    // MARK: - Mirror adoption (the read path)

    /// Adopt one mirror state: pick this VM's session row (by rename-stable
    /// "$N" id first, then by name), project it into the store (runtime
    /// registry), and republish the whole view surface.
    func adopt(_ state: TmuxStructureState) {
        guard usingTmux else { return }
        let rows = state.effectiveSessions
        var row = tmuxSessionID.flatMap { id in
            id.isEmpty ? nil : rows.first { $0.id == id }
        }
        if row == nil, let name = activeTmuxSessionName {
            row = rows.first { $0.name == name }
        }
        guard let row else {
            // Session gone from the server. The window notices through the
            // app's server-session push (absent-poll close), same as frozen.
            availableTmuxSessions = rows.map(\.name)
            return
        }
        tmuxSessionID = row.id.isEmpty ? tmuxSessionID : row.id
        if activeTmuxSessionName != row.name {
            activeTmuxSessionName = row.name   // %session-renamed follows the id
        }
        availableTmuxSessions = rows.map(\.name)

        // Store adoption: runtimes for every pane of this session (all
        // windows — background windows keep reporting state), dead panes torn
        // down by the projection swap.
        if let entry = state.workspaceEntry(entryID: entryID, sessionName: row.name) {
            _ = store.adoptTmuxProjection(entry)
            store.ensureRuntimes(session: row.name)
        }

        // Windows + panes, in mirror order.
        let sortedWindows = row.structure.windows.sorted { $0.index < $1.index }
        let newWindows = sortedWindows.map { w in
            TmuxWindow(id: TmuxWindowID(w.index), index: w.index, name: w.name,
                       layout: w.layout, isActive: w.active)
        }
        var effectiveWindows = newWindows
        if !effectiveWindows.contains(where: \.isActive), !effectiveWindows.isEmpty {
            effectiveWindows[0].isActive = true   // pre-flag mirror values
        }
        var allPanes: [Pane] = []
        for w in sortedWindows {
            let winActive = effectiveWindows.first { $0.index == w.index }?.isActive ?? false
            for d in w.orderedDetails {
                var pane = Pane(
                    id: TmuxPaneID(d.id), windowID: TmuxWindowID(w.index),
                    inActiveWindow: winActive,
                    x: d.x, y: d.y, width: d.width, height: d.height,
                    isActive: d.active, isZoomed: d.zoomed,
                    title: d.title.isEmpty ? nil : d.title,
                    currentCommand: nil)
                // The mirror carries no interaction mode (see Pane). Carry
                // the last poll's forward, or a geometry push would tell
                // every surface the pane is a plain shell again — dropping
                // the mouse to selection mid-TUI.
                if let mode = paneModes[pane.id] { pane.interactionMode = mode }
                allPanes.append(pane)
            }
        }

        if windows != effectiveWindows { windows = effectiveWindows }
        let newActiveWindowID = effectiveWindows.first(where: \.isActive)?.id ?? activeWindowID
        if activeWindowID != newActiveWindowID { activeWindowID = newActiveWindowID }
        if sessionPanes != allPanes { sessionPanes = allPanes }
        updatePaneViewModels(allPanes.filter(\.inActiveWindow))
        recomputeSessionMode()
        adoptSizing(state.sizing)
        if phase == .starting { phase = .tmuxReady; isTmuxReady = true }
    }

    private func adoptSizing(_ sizing: TmuxSizingState?) {
        guard let sizing else { return }
        let mode = TerminalSizingMode.fromTmuxWindowSize(
            sizing.policy == "pinned" ? "manual" : sizing.policy) ?? .tracking
        if sizingMode != mode { sizingMode = mode }
        let owner: TmuxSizingOwner? = (mode == .thisDevice && !sizing.ownerDevice.isEmpty)
            ? TmuxSizingOwner(client: sizing.ownerDevice, label: sizing.ownerDevice)
            : nil
        if sizingOwner != owner { sizingOwner = owner }
    }

    private func updatePaneViewModels(_ panes: [Pane]) {
        // Snapshot BEFORE updatePane mutates the reused instances, so the
        // no-change gate below compares against what was actually published.
        let oldVMs = paneViewModels
        let oldPanes = oldVMs.map(\.pane)

        var newViewModels: [PaneViewModel] = []
        var newPaneIDs: [TmuxPaneID] = []

        for pane in panes {
            if let existing = paneViewModels.first(where: { $0.paneID == pane.id }) {
                existing.updatePane(pane)
                if existing.isActive != pane.isActive { existing.isActive = pane.isActive }
                newViewModels.append(existing)
            } else {
                let runtime = store.runtime(forPane: pane.id.raw) as? TmuxPaneRuntime
                // Wire the scrollback source BEFORE the view model binds: its
                // init seeds a surface that holds no history (the panes a
                // window switch reveals), and a source wired afterwards would
                // arrive too late — the pane would sit blank until its next
                // repaint.
                if let runtime, runtime.captureScrollback == nil {
                    let link = self.link
                    let paneIndex = pane.id.raw
                    runtime.captureScrollback = {
                        try? await link.capturePaneScrollback(paneIndex)
                    }
                }
                let vm = PaneViewModel(pane: pane, runtime: runtime)
                vm.isActive = pane.isActive
                let paneID = pane.id
                vm.fetchWorkingDirectory = { [weak self] in
                    await self?.paneWorkingDirectory(paneID)
                }
                newViewModels.append(vm)
                newPaneIDs.append(pane.id)
                DIAG("newVM \(pane.id) \(pane.width)x\(pane.height)")
            }
        }

        // Equality-gate the array publish: mirror pushes usually return the
        // same panes with the same data, and every republish makes the hosts
        // re-run syncPanes/layout.
        let identical = newPaneIDs.isEmpty
            && newViewModels.count == oldVMs.count
            && zip(newViewModels, oldVMs).allSatisfy { $0 === $1 }
            && panes == oldPanes
        if !identical { paneViewModels = newViewModels }

        if let active = panes.first(where: { $0.isActive }) {
            if activePaneID != active.id { activePaneID = active.id }
            // window_zoomed_flag is per-window; the zoomed pane is the active one.
            let newZoom = active.isZoomed ? active.id : nil
            if zoomedPaneID != newZoom { zoomedPaneID = newZoom }
        } else {
            if zoomedPaneID != nil { zoomedPaneID = nil }
        }
        if !identical { onGeometryApplied?() }

        if !newPaneIDs.isEmpty {
            Task { await updatePaneStates() }
        }
    }

    private func handleStoreEvent(_ event: AgentWorkspaceStore.Event) {
        switch event {
        case .activity:
            // A runtime's detection edge — re-judge now instead of waiting
            // out the 2s poll.
            Task { await updatePaneStates() }
        case .structure, .geometry, .workspacesChanged, .historyCatalogChanged:
            break
        }
    }

    // MARK: - Actions (verbs; the mirror's next snapshot is the answer)

    public func scrollCopyMode(_ pane: TmuxPaneID, rows: Int) {
        // The mirror carries no pane_in_mode reading and the daemon has no
        // copy-mode verb yet — flagged; the surface's own scrollback owns
        // review scrolling in this product.
        _ = (pane, rows)
    }

    public func exitCopyMode(_ pane: TmuxPaneID) {
        _ = pane   // see scrollCopyMode — flagged daemon seam
    }

    public func splitPane(horizontal: Bool) {
        guard let target = activePaneID, let session = activeTmuxSessionName else { return }
        link.apply(.splitPane(session: session, target: target.raw,
                              horizontal: horizontal, cwd: nil, command: nil))
    }

    public func selectPane(_ paneID: TmuxPaneID) {
        guard usingTmux else { return }
        link.apply(.selectPane(pane: paneID.raw))
        activePaneID = paneID
        for vm in paneViewModels {
            vm.isActive = (vm.paneID == paneID)
            // Focusing a pane = seeing it → clear the "done, unseen" badge.
            if vm.paneID == paneID, vm.agentFinishedUnseen {
                vm.agentFinishedUnseen = false
            }
        }
        if paneDoneUnseen[paneID] == true {
            paneDoneUnseen[paneID] = false
            stateVersion += 1
        }
    }

    public func resizePaneBy(_ paneID: TmuxPaneID, direction: String, amount: Int) {
        link.apply(.resizePane(pane: paneID.raw, direction: direction, amount: amount))
    }

    public func toggleZoom(_ paneID: TmuxPaneID) {
        link.apply(.toggleZoom(pane: paneID.raw))
    }

    public func closePane(_ paneID: TmuxPaneID) {
        link.apply(.killPane(pane: paneID.raw))
    }

    /// Swap a pane with its previous/next neighbor (tmux `swap-pane -U/-D`,
    /// same as tmux's `{`/`}` bindings).
    public func swapPane(_ paneID: TmuxPaneID, up: Bool) {
        guard usingTmux else { return }
        link.apply(.swapPane(pane: paneID.raw, up: up))
    }

    /// Swap two specific panes (drag a pane's title bar onto another pane's
    /// CENTER drop zone).
    public func swapPanes(_ source: TmuxPaneID, with destination: TmuxPaneID) {
        guard usingTmux, source != destination else { return }
        link.apply(.swapPanes(a: source.raw, b: destination.raw))
    }

    /// Dock `source` against one edge of `target` (drag onto an EDGE drop
    /// zone): tmux re-splits the target along that axis and moves the dragged
    /// pane into the new half.
    public func movePane(_ source: TmuxPaneID, splitting target: TmuxPaneID,
                         horizontal: Bool, before: Bool) {
        guard usingTmux, source != target else { return }
        link.apply(.dockPane(source: source.raw, at: target.raw,
                             horizontal: horizontal, before: before))
    }

    /// Force a pane's detection profile (pane menu → Change Profile); nil =
    /// auto-detect. Takes effect on the next detection tick.
    public func setPaneProfile(_ profileID: String?, for paneID: TmuxPaneID) {
        stateDetection.setProfileOverride(profileID, for: paneID)
    }

    public func paneProfile(for paneID: TmuxPaneID) -> String? {
        stateDetection.profileOverride(for: paneID)
    }

    /// Rename a pane (sets `pane_title`, shown in the pane title bar / List rows).
    public func renamePane(_ paneID: TmuxPaneID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        link.apply(.renamePane(pane: paneID.raw, to: trimmed))
    }

    /// Data-layer seam (flagged): the daemon holds ONE control client per
    /// target, so only the ATTACHED session's panes stream output — where
    /// the frozen product ran one tmux -CC client per tab and streamed them
    /// all. A window coming to the front re-ensures its session so its panes
    /// go live again.
    public func ensureAttachedIfNeeded() {
        guard usingTmux, let name = activeTmuxSessionName else { return }
        guard link.attachedSessionName != name else { return }
        Task { try? await link.ensure(session: name) }
    }

    /// Switch the daemon's control client to another tmux session — the
    /// ensure IS the switch (attaches-or-creates).
    public func switchSession(_ name: String) {
        guard usingTmux, name != activeTmuxSessionName else { return }
        Task { try? await link.ensure(session: name) }
    }

    /// Rename the attached tmux session (the toolbar's "Rename Session…").
    public func renameSession(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usingTmux, !trimmed.isEmpty, trimmed != activeTmuxSessionName,
              let current = activeTmuxSessionName else { return }
        link.apply(.renameSession(name: current, to: trimmed))
        activeTmuxSessionName = trimmed   // optimistic; the mirror reconciles by $id
    }

    public func newWindow(name: String? = nil) {
        guard let session = activeTmuxSessionName else { return }
        // The daemon's newPane verb creates one pane in its own window; an
        // explicit window NAME has no verb field yet (flagged) — tmux's
        // automatic-rename names it from what runs, same as the frozen
        // default (which deliberately passed no -n).
        _ = name
        link.apply(.newPane(session: session, cwd: nil, command: nil))
    }

    /// Rename the active tmux window (the session menu's "Rename Window…").
    public func renameWindow(to newName: String) {
        guard let id = activeWindowID else { return }
        renameWindow(id, to: newName)
    }

    /// Rename a specific window — the sidebar's per-row "Rename Window…".
    /// FLAGGED: the daemon has no window-rename verb yet; the UI affordance
    /// is preserved and this logs instead of silently dropping the intent.
    public func renameWindow(_ id: TmuxWindowID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usingTmux, !trimmed.isEmpty else { return }
        dlog("renameWindow \(id) → \(trimmed): no daemon verb yet (flagged)")
    }

    /// Close the active tmux window. Closing the session's last window ends the
    /// session (tmux semantics).
    public func closeWindow() {
        guard let id = activeWindowID else { return }
        closeWindow(id)
    }

    /// Close a specific window (List mode's per-row close). Kills its
    /// processes; the daemon vocabulary is per-pane, so the window closes as
    /// its panes' kills.
    public func closeWindow(_ id: TmuxWindowID) {
        guard usingTmux else { return }
        for pane in panes(in: id) {
            link.apply(.killPane(pane: pane.id.raw))
        }
    }

    public func selectWindow(_ windowID: TmuxWindowID) {
        // selectPane is the daemon's "put my focus here" — it selects the
        // pane's window too (server-wide lookup).
        let winPanes = panes(in: windowID)
        guard let target = winPanes.first(where: \.isActive) ?? winPanes.first else { return }
        link.apply(.selectPane(pane: target.id.raw))
        // Reflect the switch immediately (the tab highlight shouldn't wait for
        // the mirror round-trip); the next push reconciles authoritatively.
        activeWindowID = windowID
        for i in windows.indices { windows[i].isActive = (windows[i].id == windowID) }
    }

    // MARK: - Direct Input

    public func sendData(_ data: Data) {
        if usingTmux, let activePaneID,
           let paneVM = paneViewModels.first(where: { $0.paneID == activePaneID }) {
            paneVM.sendInput(data)
        } else {
            predictor.willSend(data)   // draw the prediction; doesn't alter what's sent
            _ = ptyTransport?.enqueueStdio(data)
        }
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendData(data)
    }

    public func resizeTerminal(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard let ptyTransport, let ptyAgentID else { return }
        Task {
            _ = try? await ptyTransport.resizeTmuxPane(agentID: ptyAgentID, cols: cols, rows: rows)
        }
    }

    /// Declare this window's grid to the daemon's session-size authority.
    /// Under `latest` and `smallest` every client SHOULD keep declaring its
    /// own grid — that is the input the daemon resolves from; under `pinned`
    /// only the owner's declaration moves the session.
    ///
    /// Everything passes `viewportGate` first: on the trunk one daemon-side
    /// control client carries the whole session, so a declaration resizes tmux
    /// for real (reflowing every pane) instead of just announcing one client's
    /// viewport the way the frozen per-window client did. See
    /// `ViewportDeclarationGate`.
    public func resizeTmuxClient(cols: Int, rows: Int, force: Bool = false) {
        guard cols > 0, rows > 0 else { return }
        lastTmuxClientSize = (cols, rows)
        guard usingTmux else { return }
        guard let grid = viewportGate.offer(cols: cols, rows: rows, force: force) else { return }
        declare(grid)
    }

    private func declare(_ grid: (cols: Int, rows: Int)) {
        switch sizingMode {
        case .tracking, .smallest:
            link.declareViewport(cols: grid.cols, rows: grid.rows)
        case .thisDevice:
            guard sizingOwnerIsMe else { return }
            link.declareViewport(cols: grid.cols, rows: grid.rows)
        }
    }

    /// Run a structure transition (spread / merge) with size declarations held
    /// back until it settles — the intermediate shapes tmux passes through are
    /// not sizes the user asked for, and one landing mid-merge is what made
    /// `join-pane` fail with "no space for a new pane".
    func withStructureTransition<T>(_ body: () async -> T) async -> T {
        viewportGate.beginTransition()
        let result = await body()
        if let grid = viewportGate.endTransition() { declare(grid) }
        return result
    }

    /// Change who governs the session size — the daemon's setSizePolicy verb
    /// (pinned's owner is the issuing stream; the mirror's sizing block is
    /// the read path every device adopts).
    public func setSizingMode(_ mode: TerminalSizingMode) {
        sizingMode = mode
        if let session = activeTmuxSessionName {
            TerminalSizingMode.store(mode, for: session)
        }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.applySizingMode(mode)
            if mode != .thisDevice { self.resetTmuxClientToDeviceSize() }
        }
    }

    /// Put the sizing policy into the daemon. Pinning declares this window's
    /// grid first — the daemon requires a standing viewport from the pinning
    /// stream.
    @discardableResult
    public func applySizingMode(_ mode: TerminalSizingMode) async -> Bool {
        guard usingTmux else { return false }
        let policy: String
        switch mode {
        case .tracking:   policy = "latest"
        case .smallest:   policy = "smallest"
        case .thisDevice: policy = "pinned"
        }
        do {
            if mode == .thisDevice {
                let (cols, rows) = lastTmuxClientSize ?? environment.idealTerminalSize()
                // force: the daemon requires a standing viewport from the
                // pinning stream, so this one must go out even unchanged.
                _ = viewportGate.offer(cols: cols, rows: rows, force: true)
                link.declareViewport(cols: cols, rows: rows)
                _ = try await link.setSizePolicy(policy, ownerDevice: BentoDeviceLabel.current)
                sizingOwner = TmuxSizingOwner(client: BentoDeviceLabel.current,
                                              label: BentoDeviceLabel.current)
            } else {
                _ = try await link.setSizePolicy(policy)
                sizingOwner = nil
            }
            return true
        } catch {
            dlog("applySizingMode \(mode.rawValue): \(error)")
            return false
        }
    }

    /// User-triggered: make the session fit THIS device — re-declare the
    /// window's grid (needed because automatic pushes are deduplicated
    /// upstream, so a shrink by another client would otherwise never be
    /// answered).
    public func resetTmuxClientToDeviceSize() {
        guard usingTmux else { return }
        if sizingMode == .thisDevice, !sizingOwnerIsMe {
            setSizingMode(.thisDevice)
            return
        }
        let (cols, rows) = lastTmuxClientSize ?? environment.idealTerminalSize()
        // User-initiated: re-assert even if it equals what stands.
        _ = viewportGate.offer(cols: cols, rows: rows, force: true)
        link.declareViewport(cols: cols, rows: rows)
    }

    public func killSession() {
        if let name = activeTmuxSessionName {
            link.apply(.killSession(name: name))
        }
        disconnect()
    }

    public func disconnect() {
        statePollingTask?.cancel()
        statePollingTask = nil
        link.unregister(self)
        store.removeListener(self)
        // Close this session's byte pipes (daemon-hosted panes live on).
        for pane in sessionPanes {
            store.runtime(forPane: pane.id.raw)?.shutdown()
        }
        ptyTransport?.close()
        ptyTransport = nil
        ptyAgentID = nil
        let priorName = activeTmuxSessionName ?? ""
        usingTmux = false
        isTmuxReady = false
        phase = .ended
        paneViewModels = []
        rawHistoryLock.withLock { $0.removeAll(keepingCapacity: false) }
        environment.onSessionUpdate(vmID, priorName, 0, "")
    }

    // MARK: - Plain (no-tmux) daemon pty

    private func startPlainShell() async {
        do {
            let transport = AcpHostTransportFactory.local(socketPath: TermShell.socketPath)
            try await transport.connect()
            transport.onStdioUnit = { [weak self] data in
                guard let self else { return }
                // Ordered main-queue hop (not a Task) so byte order is
                // preserved, mirroring the frozen raw path's routing.
                self.appendRawHistory(data)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.predictor.didReceive(data)
                    }
                    self.onRawDataReceived?(data)
                }
            }
            transport.onEvent = { [weak self] event in
                if case .agentExited = event {
                    Task { @MainActor in self?.phase = .ended }
                }
            }
            let size = environment.idealTerminalSize()
            let info = try await transport.spawnPty(
                command: plainCommand?.first ?? "",
                args: (plainCommand?.count ?? 0) > 1 ? Array(plainCommand!.dropFirst()) : [],
                cols: size.cols, rows: size.rows)
            ptyTransport = transport
            ptyAgentID = info.agentID
            phase = .shellReady
        } catch {
            dlog("plain pty spawn failed: \(error)")
            errorMessage = String(describing: error)
            showError = true
            phase = .ended
        }
    }

    private nonisolated func appendRawHistory(_ data: Data) {
        rawHistoryLock.withLock { history in
            history.append(data)
            let overflow = history.count - Self.maxRawHistoryBytes
            if overflow > 0 { history.removeSubrange(0..<overflow) }
        }
    }

    // MARK: - State Detection

    private func startStatePolling() {
        // Idempotent: never stack a second poller.
        statePollingTask?.cancel()
        statePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { break }
                await self.updatePaneStates()
            }
        }
    }

    /// THE per-pane state judgment — one pipeline behind both the Tiled pane
    /// chrome and the List window dots: the frozen product's classifyPane
    /// ladder, restored on the daemon's status ops. Each tick pulls fresh
    /// per-pane command + title (`tmuxpanes` — the frozen VM's list-panes),
    /// feeds them to the pane runtimes, and runs the agent rule engine
    /// (braille spinner title = working, ✳ = idle, capture-pane region
    /// rules for blocked/working when the title can't tell). Panes the
    /// engine doesn't recognize keep the runtimes' legacy activity reading.
    func updatePaneStates() async {
        let statuses = await freshPaneStatuses()
        adoptPaneModes(statuses)

        var changed = false
        var awaitingCount = 0
        var sawNewAwaiting = false
        var latestPrompt = ""
        var agentWorking = 0
        var agentWaiting = 0
        var agentDoneUnseen = 0

        var newStates: [TmuxPaneID: PaneState] = [:]
        var newDone: [TmuxPaneID: Bool] = [:]

        let live = Set(paneViewModels.map(\.paneID))

        for paneVM in paneViewModels {
            let current = paneVM.paneState
            await refreshRuntimeAgentState(paneVM.paneID, statuses: statuses)
            let newState = runtimeState(paneVM.paneID)
            newStates[paneVM.paneID] = newState

            if paneVM.paneState != newState {
                // Transition INTO awaiting — fire notification + snippet.
                if case .awaitingInput = newState {
                    sawNewAwaiting = true
                    let snippet = runtimePreview(paneVM.paneID)
                    if !snippet.isEmpty { latestPrompt = snippet }
                }
                paneVM.paneState = newState
                changed = true
            }

            let done = Self.doneUnseen(isFocused: paneVM.isActive,
                                       current: current, newState: newState,
                                       prev: paneVM.agentFinishedUnseen)
            if paneVM.agentFinishedUnseen != done {
                paneVM.agentFinishedUnseen = done
                changed = true
            }
            newDone[paneVM.paneID] = done

            if case .awaitingInput = paneVM.paneState { awaitingCount += 1 }

            // Tally agent activity for the toolbar's dots.
            if paneVM.agentFinishedUnseen { agentDoneUnseen += 1 }
            switch paneVM.paneState {
            case .working:       agentWorking += 1
            case .awaitingInput: agentWaiting += 1
            case .idle:          break
            }
        }

        // Background-window panes (no live surface / runtime) go through the
        // SAME rule engine, so the window list's state can't disagree with
        // what the Tiled chrome would show. They're never focused, so
        // "done, unseen" is judged with isFocused:false.
        for pane in sessionPanes where !live.contains(pane.id) {
            let current = paneStates[pane.id] ?? .idle
            let status = statuses[pane.id]
            let state = await classifyBackgroundPane(
                id: pane.id,
                command: status?.command ?? pane.currentCommand,
                title: status?.title ?? pane.title ?? "",
                current: current)
            newStates[pane.id] = state
            if paneStates[pane.id] != state { changed = true }

            let done = Self.doneUnseen(isFocused: false,
                                       current: current, newState: state,
                                       prev: paneDoneUnseen[pane.id] ?? false)
            newDone[pane.id] = done
            if (paneDoneUnseen[pane.id] ?? false) != done { changed = true }
        }
        paneStates = newStates
        paneDoneUnseen = newDone

        if changed { stateVersion += 1 }
        if agentsWorking != agentWorking { agentsWorking = agentWorking }
        if agentsWaiting != agentWaiting { agentsWaiting = agentWaiting }
        if agentsDoneUnseen != agentDoneUnseen { agentsDoneUnseen = agentDoneUnseen }
        if sawNewAwaiting { environment.onAwaitingTriggered() }
        environment.onSessionUpdate(vmID, activeTmuxSessionName ?? "",
                                    awaitingCount, latestPrompt)
    }

    /// One pane's live working directory (`#{pane_current_path}`) off a
    /// fresh `tmuxpanes` pull — call-time like the frozen display-message
    /// query, deliberately never mirrored (it flaps with every cd).
    func paneWorkingDirectory(_ id: TmuxPaneID) async -> String? {
        await freshPaneStatuses()[id]?.path
    }

    /// The last poll's interaction-mode reading per pane — the four flags
    /// the structure mirror refuses to carry (see `Pane`). Held here so a
    /// mirror push, which knows nothing about them, can carry them forward
    /// instead of resetting every pane to "plain shell".
    private var paneModes: [TmuxPaneID: Pane.InteractionMode] = [:]

    /// One poll's rows → the mode table, keeping the previous reading when
    /// the poll says nothing. Pure so the three decisions it encodes can be
    /// pinned by test: an EMPTY reply is a failed poll (never "every pane
    /// went plain"), a missing field is a daemon too old to report it (false,
    /// the terminal default), and a pane absent from a non-empty reply is
    /// gone (dropped, so a reused pane id can't inherit a dead pane's mode).
    static func paneModes(from statuses: [TmuxPaneID: AcpTmuxPaneStatus],
                          previous: [TmuxPaneID: Pane.InteractionMode])
        -> [TmuxPaneID: Pane.InteractionMode] {
        guard !statuses.isEmpty else { return previous }
        var next: [TmuxPaneID: Pane.InteractionMode] = [:]
        for (id, row) in statuses {
            next[id] = .init(alternateOn: row.alternateOn ?? false,
                             mouseAny: row.mouseAny ?? false,
                             mouseSGR: row.mouseSGR ?? false,
                             inMode: row.inMode ?? false)
        }
        return next
    }

    /// Merge a poll's mode readings into the published panes.
    ///
    /// This is what tells a surface that a fullscreen TUI owns its pane: the
    /// program enabled the mouse (and the alternate screen) when it started,
    /// long before this surface existed, so nothing in the pane's byte
    /// stream can say so — only tmux's flags can. Without it every pane
    /// reads as a plain shell and the wheel scrolls local scrollback that a
    /// TUI pane has no business having.
    ///
    /// An EMPTY poll is a failed poll (daemon briefly unreachable), never
    /// "every pane went plain": it leaves the last reading standing.
    private func adoptPaneModes(_ statuses: [TmuxPaneID: AcpTmuxPaneStatus]) {
        let next = Self.paneModes(from: statuses, previous: paneModes)
        guard next != paneModes else { return }
        paneModes = next

        var panes = sessionPanes
        for i in panes.indices {
            panes[i].interactionMode = paneModes[panes[i].id] ?? .init()
        }
        if panes != sessionPanes { sessionPanes = panes }
        for vm in paneViewModels {
            var pane = vm.pane
            pane.interactionMode = paneModes[pane.id] ?? .init()
            vm.updatePane(pane)   // equality-gated inside
        }
    }

    /// One `tmuxpanes` pull, keyed by pane id. Empty on failure (daemon
    /// briefly unreachable) — the tick then judges on what it already has.
    private func freshPaneStatuses() async -> [TmuxPaneID: AcpTmuxPaneStatus] {
        guard let rows = try? await link.paneStatuses() else { return [:] }
        var out: [TmuxPaneID: AcpTmuxPaneStatus] = [:]
        for row in rows {
            if let id = TmuxPaneID(string: row.pane) { out[id] = row }
        }
        return out
    }

    /// Feed a live pane's runtime its fresh detection inputs and run the
    /// agent rule engine pass (TmuxPaneRuntime.refreshAgentState — the
    /// frozen classifyPane ladder, cheap title pass then capture).
    private func refreshRuntimeAgentState(
        _ id: TmuxPaneID, statuses: [TmuxPaneID: AcpTmuxPaneStatus]
    ) async {
        guard let runtime = store.runtime(forPane: id.raw) as? TmuxPaneRuntime else { return }
        if let status = statuses[id] {
            if let command = status.command, !command.isEmpty {
                runtime.currentCommand = command
            }
            if let title = status.title, !title.isEmpty {
                runtime.title = title
            }
        }
        if runtime.captureScreenText == nil {
            let link = self.link
            let pane = id.raw
            runtime.captureScreenText = { try? await link.capturePane(pane) }
        }
        await runtime.refreshAgentState()
    }

    /// Rule-engine judgment for a pane with no live runtime (background
    /// window): same ladder, VM-owned detection service (no output history
    /// back there — command/title/screen are the whole evidence, exactly
    /// the frozen background-pane path).
    private func classifyBackgroundPane(id: TmuxPaneID, command: String?,
                                        title: String, current: PaneState) async -> PaneState {
        switch backgroundDetection.classifyAgent(command: command, title: title,
                                                 snapshot: nil, pane: id, current: current) {
        case .notAgent:
            return .idle
        case .state(let state):
            return state
        case .needsSnapshot:
            let snap = try? await link.capturePane(id.raw)
            if case .state(let state) = backgroundDetection.classifyAgent(
                command: command, title: title, snapshot: snap,
                pane: id, current: current) {
                return state
            }
            return current
        }
    }

    /// A pane's detected state, read off its runtime (the trunk's detection
    /// consumed the byte stream as it arrived).
    private func runtimeState(_ id: TmuxPaneID) -> PaneState {
        guard let runtime = store.runtime(forPane: id.raw) as? TmuxPaneRuntime else {
            return .idle
        }
        if runtime.isAwaitingUserInput { return .awaitingInput(profile: "") }
        if runtime.isTurnActive { return .working }
        return .idle
    }

    private func runtimePreview(_ id: TmuxPaneID) -> String {
        (store.runtime(forPane: id.raw) as? TmuxPaneRuntime)?.previewLine ?? ""
    }

    /// Pure "done, unseen" transition, shared by live and background panes: a
    /// pane that goes idle while UNFOCUSED becomes done; staying idle keeps
    /// the memory; focusing it or leaving idle clears it. (The frozen gate
    /// additionally required agent recognition via pane_current_command —
    /// a reading the mirror deliberately omits; flagged.)
    static func doneUnseen(isFocused: Bool, current: PaneState,
                           newState: PaneState, prev: Bool) -> Bool {
        guard isIdle(newState), !isFocused else { return false }
        return isIdle(current) ? prev : true
    }

    private static func isIdle(_ s: PaneState) -> Bool {
        if case .idle = s { return true }
        return false
    }
}
