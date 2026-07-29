#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoLink
import BentoTmuxPane
import BentoWorkbench
import Combine
import Foundation
import os

/// One tmux session as the product-B shell drives it — the data spine every
/// window's chrome (tiled host, toolbar strip, Focus sidebar) binds to. It is
/// the term-shell twin of the ACP `WorkspaceViewModel`, but far leaner: there
/// is no ACP launcher ladder, no history catalog, no voice. Structure is the
/// daemon's (seam two): reads arrive as `DaemonAuthority` projections and get
/// adopted WHOLESALE into the store; writes go out as structure verbs and the
/// next mirror snapshot is the answer (never an optimistic local mutation).
///
/// One model = one NSWindow = one tmux session = one `target` (v1's
/// one-target-one-session boundary). The session's tmux WINDOWS are the
/// navigable structure: the toolbar's center strip and the Focus sidebar list
/// them; Parallel tiles the active window's panes.
@MainActor
public final class TermWorkspaceModel: ObservableObject {
    private static let log = Logger(subsystem: "com.bento.shelltermmac", category: "workspace")

    public let target: String
    public let entryID: Int
    /// The tmux session name. Adopted from the mirror once structure lands
    /// (a `%session-renamed` shows here); seeded from the requested name.
    @Published public private(set) var sessionName: String

    private let store: AgentWorkspaceStore
    private var authority: DaemonAuthority?
    private var control: AcpHostTransport?

    // MARK: Published surface (the chrome binds these)

    /// The active window's panes, in layout order with cell geometry.
    @Published public private(set) var panes: [Pane] = []
    /// The session's tmux windows (toolbar strip + Focus sidebar rows).
    @Published public private(set) var windows: [TermWindowRow] = []
    @Published public private(set) var activePaneID: PaneID?
    @Published public private(set) var zoomedPaneID: PaneID?
    /// Parallel (tiled) ⇄ Focus (one window per row). A pure view preference —
    /// switching never touches structure.
    @Published public var mode: WorkspaceViewMode = .tiled
    /// Bumped on any pane activity so cells re-read `paneStatus` without the
    /// model republishing the whole `panes` array.
    @Published public private(set) var stateVersion = 0
    /// True once the first projection has been adopted (chrome shows a spinner
    /// until then).
    @Published public private(set) var isReady = false
    /// Set when the daemon link fails — chrome surfaces it instead of an empty
    /// window that looks hung.
    @Published public private(set) var connectionError: String?

    public init(target: String = "local", sessionName: String, entryID: Int,
                store: AgentWorkspaceStore = TermShell.store) {
        self.target = target
        self.sessionName = sessionName
        self.entryID = entryID
        self.store = store
        TermShell.sessionNames[target] = sessionName
        store.addListener(self) { [weak self] event in self?.handle(event) }
    }

    // MARK: - Lifecycle

    /// Connect the control channel, ensure the session, and start ingesting the
    /// structure mirror. Idempotent-ish: a second call supersedes the first.
    public func start() {
        Task { await connect() }
    }

    private func connect() async {
        do {
            let control = AcpHostTransportFactory.local(socketPath: TermShell.socketPath)
            try await control.connect()
            // Ensure the session exists before the mirror is read (idempotent —
            // the daemon adopts a live control client).
            _ = try await control.ensureTmux(target: target, sessionName: sessionName)
            self.control = control
            // `.linked` wires the statechanged subscription + does an initial
            // pull; that pull fires before we can set `onProjection`, so we
            // adopt `lastState` by hand right after.
            let authority = await DaemonAuthority.linked(
                to: control, target: target, entryID: entryID)
            authority.onProjection = { [weak self] entry, state in
                self?.adopt(entry, state: state)
            }
            self.authority = authority
            if let state = authority.lastState,
               let entry = state.workspaceEntry(entryID: entryID) {
                adopt(entry, state: state)
            }
            connectionError = nil
        } catch {
            Self.log.error("term workspace connect failed: \(String(describing: error))")
            connectionError = String(describing: error)
        }
    }

    /// Adopt a projected structure snapshot: swap it into the store, attach any
    /// new pane's runtime, and republish the view surface.
    private func adopt(_ entry: AgentWorkspaceStore.WorkspaceEntry,
                       state: TmuxStructureState) {
        let name = store.adoptTmuxProjection(entry)
        sessionName = name
        TermShell.sessionNames[target] = name
        // Build/attach a runtime for every pane (idempotent — reuses existing).
        store.ensureRuntimes(session: name)
        windows = TermWindowRow.rows(from: state)
        isReady = true
        refreshPanes()
    }

    private func refreshPanes() {
        let list = store.paneList(session: sessionName)
        panes = list
        activePaneID = list.first(where: \.isActive)?.id ?? list.first?.id
        zoomedPaneID = list.first(where: \.isZoomed)?.id
    }

    private func handle(_ event: AgentWorkspaceStore.Event) {
        switch event {
        case .structure(let name) where name == sessionName:
            refreshPanes()
        case .geometry(let name, _) where name == sessionName:
            refreshPanes()
        case .activity:
            stateVersion &+= 1
        case .workspacesChanged, .structure, .geometry, .historyCatalogChanged:
            break
        }
    }

    /// App teardown: close streams (daemon-hosted panes live on).
    public func teardown() {
        store.removeListener(self)
        for pane in panes { store.runtime(forPane: pane.id.raw)?.shutdown() }
        control?.close()
        control = nil
        authority = nil
    }

    // MARK: - Reads the chrome needs

    /// A pane's visual status, read live off its runtime (no local mirror).
    public func paneStatus(_ paneID: Int) -> PaneDisplayStatus {
        guard let runtime = store.runtime(forPane: paneID) else { return .idle }
        if runtime.isAwaitingUserInput { return .awaiting }
        if runtime.hasCompletedTurn, activePaneID?.raw != paneID { return .doneUnseen }
        if runtime.isTurnActive { return .working }
        return .idle
    }

    /// Aggregate the session's pane activity for the toolbar's session dot.
    public var aggregateStatus: PaneDisplayStatus {
        var sawWorking = false, sawDone = false
        for pane in panes {
            switch paneStatus(pane.id.raw) {
            case .awaiting: return .awaiting
            case .doneUnseen: sawDone = true
            case .working: sawWorking = true
            case .idle: break
            }
        }
        if sawDone { return .doneUnseen }
        if sawWorking { return .working }
        return .idle
    }

    // MARK: - View verbs (local, never structural)

    public func setMode(_ mode: WorkspaceViewMode) { self.mode = mode }

    /// Focus a pane locally AND tell the daemon (tmux `select-pane`), so other
    /// devices converge and the mirror's active flag follows.
    public func selectPane(_ paneID: PaneID) {
        activePaneID = paneID
        authority?.apply(.selectPane(pane: paneID.raw))
    }

    public func selectWindowIndex(_ index: Int) {
        // ⌘0-9 → the window whose tmux index is that digit (sparse honored).
        guard windows.contains(where: { $0.index == index }) else { return }
        // No dedicated select-window verb in the encoding yet; selecting the
        // window's first pane brings that window forward (tmux follows the
        // active pane). Flagged: a first-class select-window verb is a daemon
        // extension (the mirror carries no window-active flag either).
        authority?.apply(.selectPane(pane: windowFirstPane(index) ?? -1))
    }

    private func windowFirstPane(_ index: Int) -> Int? {
        windows.first { $0.index == index }?.firstPaneID
    }

    // MARK: - Structure verbs (daemon-owned; the mirror is the answer)

    public func splitActivePane(horizontal: Bool) {
        guard let active = activePaneID else { return }
        authority?.apply(.splitPane(session: sessionName, target: active.raw,
                                    horizontal: horizontal, cwd: nil, command: nil))
    }

    public func closeActivePane() {
        guard let active = activePaneID else { return }
        authority?.apply(.killPane(pane: active.raw))
    }

    public func closePane(_ paneID: PaneID) {
        authority?.apply(.killPane(pane: paneID.raw))
    }

    public func toggleZoomActive() {
        guard let active = activePaneID else { return }
        authority?.apply(.toggleZoom(pane: active.raw))
    }

    public func swapActivePane(up: Bool) {
        guard let active = activePaneID else { return }
        authority?.apply(.swapPane(pane: active.raw, up: up))
    }

    public func swapPanes(_ a: PaneID, _ b: PaneID) {
        authority?.apply(.swapPanes(a: a.raw, b: b.raw))
    }

    public func dockPane(_ source: PaneID, splitting target: PaneID,
                         horizontal: Bool, before: Bool) {
        authority?.apply(.dockPane(source: source.raw, at: target.raw,
                                   horizontal: horizontal, before: before))
    }

    public func resizeBoundary(_ paneID: PaneID, direction: String, amount: Int) {
        authority?.apply(.resizePane(pane: paneID.raw, direction: direction, amount: amount))
    }

    public func renamePane(_ paneID: PaneID, to title: String) {
        authority?.apply(.renamePane(pane: paneID.raw, to: title))
    }

    // MARK: Window (tmux window) verbs — the Focus sidebar / toolbar strip

    /// New tmux window in this session (⌘T / sidebar "New Window"). tmux window
    /// creation rides `newPane` at the session level in the current encoding;
    /// a dedicated new-window verb is a daemon extension (flagged).
    public func newWindow() {
        authority?.apply(.newPane(session: sessionName, cwd: nil, command: nil))
    }

    public func renameWindow(_ index: Int, to name: String) {
        // Window rename maps to the session's structure; the encoding names
        // renameSession for the session and renamePane for panes. A window-level
        // rename verb is a daemon extension — flagged. Left as a no-op-safe
        // apply so the UI wiring is complete for when the verb lands.
        _ = (index, name)
    }

    public func moveWindow(_ index: Int, toSession session: String) {
        _ = (index, session)   // window-move verb: daemon extension (flagged)
    }

    public func killSession() {
        authority?.apply(.killSession(name: sessionName))
    }

    public func renameSession(to newName: String) {
        authority?.apply(.renameSession(name: sessionName, to: newName))
    }
}

/// One tmux window as the toolbar strip / Focus sidebar shows it. Built from
/// the structure mirror (`TmuxStructureState`); the mirror carries no
/// window-active flag yet, so "active" is the lowest-indexed (Parallel) window
/// — flagged in the port notes, matching TmuxStructureProjection.
public struct TermWindowRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public let index: Int
    public let name: String
    public let paneCount: Int
    public let active: Bool
    public let firstPaneID: Int?

    public var displayName: String { "\(index):\(name)" }

    static func rows(from state: TmuxStructureState) -> [TermWindowRow] {
        let sorted = state.structure.windows.sorted { $0.index < $1.index }
        let activeIndex = sorted.first?.index
        return sorted.map { w in
            TermWindowRow(
                id: w.index, index: w.index, name: w.name,
                paneCount: w.panes.count, active: w.index == activeIndex,
                firstPaneID: w.panes.first)
        }
    }
}
#endif
