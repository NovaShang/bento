import Foundation
import SwiftUI

/// How to enter a workspace session.
public enum SessionStartChoice: Hashable {
    /// Create or attach to a workspace session by name.
    case createOrAttach(name: String)
    /// Build a session matching `spec` (working dir, agent command, layout),
    /// then attach.
    case createAgent(spec: AgentSpec)
}

/// High-level session lifecycle.
public enum SessionPhase: Equatable {
    case starting     // syncing with the daemon / applying the start choice
    case ready        // session attached, panes live
    case suspended    // app backgrounded
    case ended
}

/// Host-app services the cross-platform view model needs but that are
/// platform-specific (haptics, Live Activity, notifications). Keeps
/// UIKit/AppKit specifics out of the shared logic.
@MainActor
public struct WorkspaceEnvironment {
    /// Fired when a pane transitions into awaiting-input (iOS: haptic).
    public var onAwaitingTriggered: () -> Void
    /// Fired on each state pass so the host can update aggregate UI
    /// (iOS: Live Activity; macOS: notification/badge). Args: hostID,
    /// session name, awaiting pane count, latest prompt snippet.
    public var onSessionUpdate: (_ hostID: UUID, _ workspaceName: String, _ awaitingPanes: Int, _ latestPrompt: String) -> Void

    public init(
        onAwaitingTriggered: @escaping () -> Void = {},
        onSessionUpdate: @escaping (_ hostID: UUID, _ workspaceName: String, _ awaitingPanes: Int, _ latestPrompt: String) -> Void = { _, _, _, _ in }
    ) {
        self.onAwaitingTriggered = onAwaitingTriggered
        self.onSessionUpdate = onSessionUpdate
    }
}

/// One attached workspace session as the views consume it: the pane list with
/// geometry, the active/zoomed pane, per-pane activity state, and the session
/// verbs (split/select/zoom/close/move/rename). A thin observation facade over
/// `AgentWorkspaceStore` — the store owns structure and agent runtimes; this
/// binds ONE session of it to a window/screen.
@MainActor
public final class WorkspaceViewModel: ObservableObject {
    @Published public var paneViewModels: [PaneViewModel] = []
    @Published public var activePaneID: PaneID?
    /// The currently zoomed pane, or nil. When set, the tiled host shows only
    /// this pane filling the window.
    @Published public var zoomedPaneID: PaneID?
    /// Every pane in the attached session, refreshed together with
    /// `paneViewModels`.
    @Published public private(set) var sessionPanes: [Pane] = []
    /// The user-facing "Parallel (tiled) | Focus (list)" view mode — a pure
    /// presentation preference, remembered per session.
    @Published public internal(set) var workspaceMode: WorkspaceViewMode = .tiled
    /// The user's last explicit mode choice (UserDefaults, per session).
    var savedModePreference: WorkspaceViewMode?
    /// One-shot latch for the initial mode-preference read.
    var modePreferenceLoaded = false
    @Published public var isSessionReady = false

    /// Where we are in the session lifecycle.
    @Published public var phase: SessionPhase = .starting

    /// Sessions in the workspace store (the session switcher's list).
    @Published public var availableSessions: [String] = []
    @Published public var sessionsLoading: Bool = false

    /// Incremented on each state pipeline cycle to trigger SwiftUI re-render.
    @Published public var stateVersion: Int = 0

    /// Per-pane state for EVERY pane in the session, computed by the one
    /// pipeline in `updatePaneStates` — what the sidebar rows and tab dots
    /// read, so they can never disagree with the pane chrome.
    var paneStates: [PaneID: PaneState] = [:]

    /// Session-wide "done, unseen" flag per pane (an agent that finished its
    /// turn while unfocused → the green ✓). Mirrors
    /// `PaneViewModel.agentFinishedUnseen`. Filled by `updatePaneStates`.
    var paneDoneUnseen: [PaneID: Bool] = [:]

    /// Panes that have done genuine work (ran a turn or sat awaiting input) in
    /// their current non-idle episode — the gate for earning the green ✓ when
    /// they next settle to idle. A pane that only "worked" because its runtime
    /// was `.starting` (fresh spawn, or a reconnect after a dropped transport)
    /// is absent here, so settling back to idle does NOT flash it green.
    private var paneRealWork: Set<PaneID> = []

    /// Live agent activity across the session's panes — drives the macOS
    /// toolbar's center summary ("N working · M waiting").
    @Published public var agentsWorking: Int = 0
    @Published public var agentsWaiting: Int = 0
    /// Agent panes that finished their turn while unfocused (the "done,
    /// unseen" state) — drives the session tab's status dot.
    @Published public var agentsDoneUnseen: Int = 0

    public let host: Host
    /// The workspace store backing this session's agents.
    public let workspace: AgentWorkspaceStore
    let environment: WorkspaceEnvironment

    /// Whether a workspace session is attached (the panes are live).
    private(set) var attached = false

    /// Active workspace session name (kill/rename/switch target).
    @Published public internal(set) var activeWorkspaceName: String?

    /// Identity token for the store listener — lets deinit (nonisolated)
    /// remove the registration without capturing self.
    private let listenerToken = NSObject()

    /// True while the app is backgrounded (or transitioning there).
    private var isInBackground = false
    /// The live phase captured when the session was suspended, restored on
    /// resume.
    private var phaseBeforeSuspend: SessionPhase?

    private var statePollingTask: Task<Void, Never>?

    public init(host: Host, workspace: AgentWorkspaceStore,
                environment: WorkspaceEnvironment) {
        self.host = host
        self.workspace = workspace
        self.environment = environment
    }

    deinit {
        // The listener closure holds weak self; sweep the registration on the
        // main actor via the token (self is gone by the time the task runs).
        let workspace = workspace
        let token = listenerToken
        Task { @MainActor in workspace.removeListener(token) }
    }

    // MARK: - Start / attach

    /// Enter a session: sync the store with the daemon (best-effort — the
    /// local cache still attaches when the daemon is unreachable), create the
    /// session if the choice asks for one, and attach.
    public func start(_ choice: SessionStartChoice) async {
        phase = .starting
        await workspace.syncWithDaemon()
        switch choice {
        case .createOrAttach(let name):
            await attachWorkspaceSession(name)
        case .createAgent(let spec):
            dlog("Creating agent session \(spec.workspaceName) (\(spec.layout.paneCount) panes)")
            workspace.createAgentSession(spec)
            await attachWorkspaceSession(spec.workspaceName)
        }
    }

    /// Attach this VM to a workspace session: ensure it exists, spawn its
    /// agent runtimes, subscribe to store events, publish the panes.
    private func attachWorkspaceSession(_ name: String) async {
        attached = true
        let canonical = workspace.ensureWorkspace(name)
        activeWorkspaceName = canonical
        workspace.ensureRuntimes(session: canonical)
        workspace.addListener(listenerToken) { [weak self] event in
            self?.handleWorkspaceEvent(event)
        }
        await refreshPanes()
        dlog("workspace ready: \(self.paneViewModels.count) panes in \(canonical)")
        isSessionReady = true
        phase = .ready
        startStatePolling()
        await refreshSessions()
    }

    /// Refresh the session list from the workspace store.
    public func refreshSessions() async {
        guard !sessionsLoading else { return }
        sessionsLoading = true
        defer { sessionsLoading = false }
        availableSessions = workspace.sessionList.map(\.name)
    }

    // MARK: - Store events

    private func handleWorkspaceEvent(_ event: AgentWorkspaceStore.Event) {
        switch event {
        case .structure(let session):
            guard session == activeWorkspaceName else { return }
            // Panes added by another device (statekv adoption) need their
            // agent runtimes before the refresh lists them.
            workspace.ensureRuntimes(session: session)
            Task { await refreshPanes() }
        case .geometry(let session, let layout):
            guard session == activeWorkspaceName else { return }
            applyLayoutGeometry(layout)
            Task { await refreshPanes() }
        case .activity(let pane):
            guard workspace.workspaceName(ofPane: pane) == activeWorkspaceName else { return }
            updatePaneStates()
        case .workspacesChanged:
            availableSessions = workspace.sessionList.map(\.name)
        case .historyCatalogChanged:
            break  // History UI observes the store directly.
        }
    }

    // MARK: - Pane management

    public func refreshPanes() async {
        guard let name = activeWorkspaceName else { return }
        let panes = workspace.paneList(session: name)
        // The attached session vanished (killed here or on another device):
        // keep the last published state; the owning UI tears the tab down.
        guard !panes.isEmpty else { return }
        if sessionPanes != panes { sessionPanes = panes }
        updatePaneViewModels(panes)
        recomputeWorkspaceMode()
        // A pane's runtime can be swapped (reset → new conversation) without any
        // change to the Pane projection, so the $paneViewModels publish is gated
        // out. Signal unconditionally so the host can re-bind surfaces whose
        // agent changed underneath them. Cheap + idempotent (host attaches only
        // when the runtime identity actually differs).
        onPanesRefreshed?()
    }

    /// Fired after every pane refresh so the view layer can reconcile per-pane
    /// bindings the `$paneViewModels` equality gate would otherwise hide (e.g. a
    /// reset that replaces a pane's agent runtime in place).
    public var onPanesRefreshed: (() -> Void)?

    /// Apply pure geometry from the layout tree to the existing panes,
    /// immediately and synchronously, so their views resize before any
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
    /// The view layer sets this to re-tile its panes.
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
        guard let name = activeWorkspaceName else { return }
        guard let target = activePaneID?.raw ?? workspace.workspace(name)?.activePane else { return }
        _ = workspace.splitPane(session: name, target: target, horizontal: horizontal,
                                cwd: nil, command: nil)
    }

    /// Drag-reorder the sidebar's pane rows: apply the list move to the
    /// current pane order and hand the store the new permutation. The store's
    /// structure emit refreshes `sessionPanes` in the new order.
    public func reorderPanes(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard attached, let name = activeWorkspaceName else { return }
        var order = sessionPanes.map(\.id.raw)
        order.move(fromOffsets: source, toOffset: destination)
        workspace.reorderPanes(session: name, order: order)
    }

    public func selectPane(_ paneID: PaneID) {
        guard attached else { return }
        workspace.selectPane(paneID.raw)
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
        workspace.resizePane(paneID.raw, direction: direction, amount: amount)
    }

    public func toggleZoom(_ paneID: PaneID) {
        workspace.toggleZoom(paneID.raw)
    }

    public func closePane(_ paneID: PaneID) {
        workspace.killPane(paneID.raw)
    }

    /// Swap a pane with its previous/next neighbor in layout order.
    public func swapPane(_ paneID: PaneID, up: Bool) {
        guard attached else { return }
        workspace.swapPane(paneID.raw, up: up)
    }

    /// Swap two specific panes (drag a pane's title bar onto another pane's
    /// CENTER drop zone).
    public func swapPanes(_ source: PaneID, with destination: PaneID) {
        guard attached, source != destination else { return }
        workspace.swapPanes(source.raw, destination.raw)
    }

    /// Dock `source` against one edge of `target` (drag onto an EDGE drop
    /// zone): the target's cell splits along that axis and the dragged pane
    /// lands in the new half, focused.
    public func movePane(_ source: PaneID, splitting target: PaneID,
                         horizontal: Bool, before: Bool) {
        guard attached, source != target else { return }
        workspace.dockPane(source.raw, at: target.raw, horizontal: horizontal, before: before)
    }

    /// Rename a pane (shown in the pane title bar / sidebar rows).
    public func renamePane(_ paneID: PaneID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspace.renamePane(paneID.raw, to: trimmed)
    }

    /// Point this VM at another workspace session (the session switcher).
    public func switchSession(_ name: String) {
        guard attached, name != activeWorkspaceName,
              workspace.workspace(name) != nil else { return }
        activeWorkspaceName = name
        workspace.ensureRuntimes(session: name)
        Task {
            await refreshPanes()
            updatePaneStates()
        }
    }

    /// Rename the attached session (the toolbar's "Rename Session…").
    public func renameSession(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard attached, !trimmed.isEmpty,
              let current = activeWorkspaceName, trimmed != current else { return }
        workspace.renameSession(current, to: trimmed)
        // The store refuses colliding names; adopt only what actually took.
        activeWorkspaceName = workspace.workspace(trimmed) != nil ? trimmed : current
        Task { await refreshSessions() }
    }

    /// Open a fresh pane in the session (largest-cell insertion).
    public func newPane() {
        guard let session = activeWorkspaceName else { return }
        _ = workspace.newPane(session: session, cwd: nil, command: nil)
    }

    // MARK: - Input routing

    /// Route text/keys to the active pane's agent composer.
    public func sendData(_ data: Data) {
        guard attached, let activePaneID,
              let paneVM = paneViewModels.first(where: { $0.paneID == activePaneID })
        else { return }
        paneVM.sendInput(data)
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendData(data)
    }

    // MARK: - Lifecycle

    public func killSession() {
        if let name = activeWorkspaceName {
            workspace.killSession(name)
        }
        disconnect()
    }

    /// Detach this VM from the session (agents keep running in the daemon).
    public func disconnect() {
        statePollingTask?.cancel()
        statePollingTask = nil
        workspace.removeListener(listenerToken)
        let priorName = activeWorkspaceName ?? ""
        attached = false
        isSessionReady = false
        phase = .ended
        paneViewModels = []
        environment.onSessionUpdate(host.id, priorName, 0, "")
    }

    /// Called when the app enters background. Cancel the polling loop and
    /// mark the phase; the daemon keeps the agents alive — re-sync on resume.
    public func suspendForBackground() {
        isInBackground = true
        statePollingTask?.cancel()
        statePollingTask = nil
        switch phase {
        case .ready:
            phaseBeforeSuspend = phase
            phase = .suspended
        case .starting:
            phaseBeforeSuspend = nil
            phase = .suspended
        case .suspended, .ended:
            break
        }
    }

    /// Called when the app returns to foreground: restore the phase and catch
    /// up on anything that changed while frozen (daemon statekv + instances).
    public func resumeFromBackground() async {
        isInBackground = false
        guard phase == .suspended else { return }
        phase = phaseBeforeSuspend ?? .ready
        phaseBeforeSuspend = nil
        guard phase == .ready else { return }
        startStatePolling()
        await workspace.syncWithDaemon()
        await refreshPanes()
        updatePaneStates()
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
            let runtime = workspace.runtime(forPane: paneVM.paneID.raw)
            let newState = classifyPane(id: paneVM.paneID)
            newStates[paneVM.paneID] = newState

            // "Settling" = the runtime is coming up (fresh spawn) or reattaching
            // after a dropped connection: it reads as `.working` for the chrome
            // (blue, "live not dead") but no turn is running. It must stay
            // transparent to the done-unseen machine — neither setting nor
            // clearing the green ✓ — else every idle pane flashes green on
            // reconnect. A genuine mid-turn reattach has `isTurnActive == true`,
            // so it is NOT settling and counts as real work below.
            let isSettling = runtime == nil
                || (runtime?.phase == .starting && runtime?.isTurnActive != true)
            // Remember genuine work (a live turn, or an awaiting-input prompt)
            // so the pane earns the badge when it later settles to idle. Sticky
            // across the whole non-idle episode; consumed on reaching idle.
            if runtime?.isTurnActive == true || newState == .awaitingInput {
                paneRealWork.insert(paneVM.paneID)
            }
            let didRealWork = paneRealWork.contains(paneVM.paneID)

            if paneVM.paneState != newState {
                // Transition INTO awaiting — fire haptic + snippet. The
                // pending permission line IS the prompt.
                if newState == .awaitingInput {
                    sawNewAwaiting = true
                    let snippet = runtime?.previewLine ?? ""
                    if !snippet.isEmpty { latestPrompt = snippet }
                }
                paneVM.paneState = newState
                changed = true
            }

            if updateSeen(paneVM, to: newState,
                          isSettling: isSettling, didRealWork: didRealWork) {
                changed = true
            }
            // The non-idle episode is over — start the next one fresh so a later
            // spawn/reconnect `.working` can't reuse this turn's "did work" bit.
            if newState == .idle && !isSettling {
                paneRealWork.remove(paneVM.paneID)
            }
            newDone[paneVM.paneID] = paneVM.agentFinishedUnseen

            if paneVM.paneState == .awaitingInput {
                awaitingCount += 1
            }

            // Tally agent activity for the toolbar's center summary.
            if paneVM.agentFinishedUnseen { agentDoneUnseen += 1 }
            switch paneVM.paneState {
            case .working:       agentWorking += 1
            case .awaitingInput: agentWaiting += 1
            case .idle:          break
            }
        }
        if paneStates != newStates { changed = true }
        paneStates = newStates
        paneDoneUnseen = newDone
        // Drop tracking for panes that no longer exist.
        paneRealWork.formIntersection(newStates.keys)

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
        environment.onSessionUpdate(host.id, activeWorkspaceName ?? "", awaitingCount, latestPrompt)
    }

    /// THE per-pane state judgment — exact, read straight off the pane's
    /// agent-turn lifecycle.
    private func classifyPane(id: PaneID) -> PaneState {
        guard let runtime = workspace.runtime(forPane: id.raw) else {
            return .working   // record exists, agent still spawning
        }
        if runtime.isAwaitingUserInput || runtime.phase == .authRequired {
            return .awaitingInput
        }
        if runtime.isTurnActive || runtime.phase == .starting {
            return .working
        }
        return .idle
    }

    /// Maintain the "done, unseen" flag. A pane that finishes genuine work
    /// while unfocused becomes done(unseen); focusing it or starting fresh work
    /// clears it. Returns true if the flag changed.
    @discardableResult
    private func updateSeen(_ paneVM: PaneViewModel, to newState: PaneState,
                            isSettling: Bool, didRealWork: Bool) -> Bool {
        let want = Self.doneUnseen(isFocused: paneVM.isActive, newState: newState,
                                   isSettling: isSettling, didRealWork: didRealWork,
                                   prev: paneVM.agentFinishedUnseen)
        guard paneVM.agentFinishedUnseen != want else { return false }
        paneVM.agentFinishedUnseen = want
        return true
    }

    /// Pure "done, unseen" transition. A pane earns the green ✓ only when it
    /// settles to idle AFTER doing genuine work (a real turn, or an
    /// awaiting-input prompt) while UNFOCUSED. Key exclusion: a pane that is
    /// merely `settling` — a fresh spawn or a reconnect that reads as
    /// `.working` but never ran a turn — is transparent, keeping whatever badge
    /// it already had rather than manufacturing a false completion. Focusing it
    /// clears it; starting a new turn (working, not settling) clears the stale
    /// badge; staying idle keeps the memory.
    static func doneUnseen(isFocused: Bool, newState: PaneState,
                           isSettling: Bool, didRealWork: Bool, prev: Bool) -> Bool {
        if isFocused { return false }
        if isSettling { return prev }
        guard newState == .idle else { return false }
        return didRealWork ? true : prev
    }
}

// MARK: - Modes, naming, creation, moves

public extension WorkspaceViewModel {
    /// Apply the remembered view-mode preference. Called after every pane
    /// refresh.
    internal func recomputeWorkspaceMode() {
        loadModePreferenceIfNeeded()
        let mode = savedModePreference ?? .tiled
        if mode != workspaceMode { workspaceMode = mode }
    }

    /// Per-session persistence key for the view mode.
    private var modePreferenceKey: String {
        "bento_view_mode_\(activeWorkspaceName ?? host.name)"
    }

    /// One-shot read of the session's remembered mode.
    private func loadModePreferenceIfNeeded() {
        guard !modePreferenceLoaded else { return }
        modePreferenceLoaded = true
        if let raw = UserDefaults.standard.string(forKey: modePreferenceKey),
           let saved = WorkspaceViewMode(rawValue: raw) {
            savedModePreference = saved
        }
    }

    /// Switch the view mode. A pure presentation toggle — zero structure
    /// changes, always lossless.
    func setMode(_ mode: WorkspaceViewMode) {
        savedModePreference = mode
        UserDefaults.standard.set(mode.rawValue, forKey: modePreferenceKey)
        if workspaceMode != mode { workspaceMode = mode }
    }

    // MARK: Naming & status

    /// The LIVE display name for a pane: its title (user rename, else the
    /// runtime's live title, else cwd), else its agent command. Sidebar
    /// rows, Focus tabs and the menubar all read this.
    func paneDisplayName(_ paneID: PaneID) -> String {
        let pane = sessionPanes.first { $0.id == paneID }
        return [pane?.title, pane?.currentCommand]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "agent"
    }

    /// One pane's raw state from the shared pipeline cache (public accessor —
    /// the dict itself is module-internal). The phone's tab dots read this.
    func paneState(_ paneID: PaneID) -> PaneState {
        paneStates[paneID] ?? .idle
    }

    /// One pane's display status: awaiting → working → done-unseen → idle.
    /// Reads the `paneStates` / `paneDoneUnseen` caches the one pipeline
    /// fills, so rows stay in lockstep with the pane chrome.
    func paneStatus(_ paneID: PaneID) -> PaneDisplayStatus {
        if let state = paneStates[paneID] {
            if state == .awaitingInput { return .awaiting }
            if state == .working { return .working }
        }
        if paneDoneUnseen[paneID] == true { return .doneUnseen }
        return .idle
    }

    // MARK: Creation (identical in both modes; only the landing differs)

    /// The active pane's working directory (nil if unknown). Seeds the New
    /// Pane / Split directory picker.
    func activePaneWorkingDirectory() async -> String? {
        guard let id = activePaneID else { return nil }
        return workspace.paneCwd(id.raw)
    }

    /// List (Focus) mode: open a new pane seeded per `seed`.
    func newFocusPane(_ seed: PaneSeed) async {
        guard attached, let session = activeWorkspaceName else { return }
        let (path, command) = resolveSeed(seed)
        _ = workspace.newPane(session: session, cwd: path, command: command)
        await refreshPanes()
    }

    /// Tiled mode: split the active pane, seeded per `seed` (creation parity
    /// with List — duplicate current / specify path+command).
    func splitPane(horizontal: Bool, seed: PaneSeed) async {
        guard attached, let session = activeWorkspaceName else { return }
        let (path, command) = resolveSeed(seed)
        guard let target = activePaneID?.raw ?? workspace.workspace(session)?.activePane else { return }
        _ = workspace.splitPane(session: session, target: target, horizontal: horizontal,
                                cwd: path, command: command)
        await refreshPanes()
    }

    /// Resolve a seed to (path, command). "Duplicate current" reads the
    /// active pane's cwd and start command from the store; a pane with no
    /// recorded start command duplicates as its preset's agent command.
    private func resolveSeed(_ seed: PaneSeed) -> (String?, String?) {
        switch seed {
        case .custom(let path, let command):
            return (blankToNil(path), blankToNil(command))
        case .duplicateCurrent:
            guard let pane = activePaneID else { return (nil, nil) }
            let path = workspace.paneCwd(pane.raw)
            if let start = blankToNil(workspace.paneStartCommand(pane.raw)) {
                return (path, start)
            }
            return (path, blankToNil(workspace.paneCurrentCommand(pane.raw)))
        }
    }

    private func blankToNil(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // MARK: Cross-session moves

    /// Move a pane out of this session into `target`. The pane's agent
    /// travels untouched — pane IDs are store-global. The one landing
    /// semantic: the target's active cell splits. Creates the target session
    /// when it doesn't exist yet ("New Session…" funnels through here), and
    /// kills the fresh session's placeholder pane afterwards so the target
    /// holds exactly the moved pane.
    ///
    /// Moving the session's LAST pane destroys the source under this client,
    /// so the client FOLLOWS: adopt the target first, then move.
    @discardableResult
    func movePane(_ paneID: PaneID, toSession target: String) async -> Bool {
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard attached, !name.isEmpty, name != activeWorkspaceName else { return false }

        // A fresh session is born with a default-agent placeholder pane;
        // remember it so exactly the moved pane remains after the move.
        var placeholder: Int?
        if workspace.workspace(name) == nil {
            workspace.createSession(name)
            guard workspace.workspace(name) != nil else { return false }
            placeholder = workspace.workspace(name)?.panes.first?.id
        }

        let isLast = sessionPanes.count <= 1
        if isLast {
            // Source about to die → follow BEFORE the move.
            activeWorkspaceName = name
            workspace.ensureRuntimes(session: name)
        }

        guard workspace.movePane(paneID.raw, toSession: name) else {
            dlog("movePane \(paneID): move → \(name) failed")
            return false
        }
        if let placeholder {
            workspace.killPane(placeholder)
        }

        await refreshPanes()
        await refreshSessions()   // warm the list for the next menu open
        return true
    }

    // MARK: - Session history

    /// The shortlist for the Focus-mode sidebar's History menu: the most
    /// recent non-expired conversations across ALL folders, newest first,
    /// deduped — NOT scoped to the active pane's directory (a session run
    /// elsewhere should still be one tap away). Folder-scoped browsing lives
    /// in the full, searchable history panel.
    func recentHistory(limit: Int = 15) -> [CatalogEntry] {
        var entries: [CatalogEntry] = []
        var seen = Set<String>()
        for entry in workspace.catalogEntries()
        where !entry.expired && seen.insert(entry.acpSessionID).inserted {
            entries.append(entry)
        }
        return Array(entries.prefix(limit))
    }

    /// ACP session ids running live in some pane — the History menu's "live"
    /// rows jump to that pane instead of respawning.
    var liveHistoryIDs: Set<String> { workspace.liveSessionIDs }

    /// Resume a history entry in the active session: respawn its agent and
    /// replay through session/load (or jump to the pane already running it).
    /// The store's structure emit refreshes the sidebar and makes the pane
    /// active; the extra refresh lands it without waiting on the event.
    func openHistory(_ entry: CatalogEntry) async {
        guard attached, let session = activeWorkspaceName else { return }
        _ = workspace.openHistorySession(entry, inSession: session)
        await refreshPanes()
    }
}

// MARK: - Voice

public extension WorkspaceViewModel {
    /// Apply a voice result to the active pane, per the glass-zone release.
    /// Shared by iOS + macOS (both just hand off the `VoiceInputResult`).
    /// none = insert into the pane's composer draft (routeInput's text path),
    /// up = insert + a distinct CR (submit), down = discarded upstream.
    func handleVoiceResult(_ result: VoiceInputResult) {
        switch result.direction {
        case .none:
            sendString(result.text)
        case .up:
            sendString(result.text)
            sendReturnDistinct()
        case .down:
            break
        }
    }

    /// Send Enter as its OWN keystroke, shortly after the text, so the
    /// composer's submit sees a standalone CR.
    private func sendReturnDistinct() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            if let data = "\r".data(using: .utf8) { sendData(data) }
        }
    }
}
