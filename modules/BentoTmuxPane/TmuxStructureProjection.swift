import BentoTerminalPane
import BentoWorkbench
import Foundation

// The read path of seam two, decoded: the daemon mirrors each tmux target's
// structure into statekv (`tmux/<target>/structure`, docs/tmux-host-design.md
// §结构镜像), and this file turns that JSON into the workspace vocabulary —
// a WorkspaceEntry whose LayoutTree is a READ-ONLY projection of tmux's own
// geometry. Nothing here writes: mutations are verbs through
// `TmuxAuthority`, and the next snapshot is the answer.

/// Wire mirror of the daemon's `tmuxStructureState` (acphost/tmuxpane.go).
/// `rev` is monotonic per target — the projection's staleness guard.
///
/// Multi-session (additive, 2cee93e): `sessions` lists EVERY session on the
/// target's REAL default-socket server, in list-sessions order, exactly one
/// `attached`; the top-level `session`/`structure` pair stays as the
/// attached alias for old values that lack `sessions`. `sizing` is the
/// session-size authority block (步骤 5.5) — policy + pinning device label +
/// the governing size the daemon's control client declares.
public struct TmuxStructureState: Codable, Sendable, Equatable {
    public var rev: UInt64
    public var target: String
    public var session: String
    public var structure: TmuxStructureSnapshot
    /// Additive: absent on pre-5.5 values.
    public var sizing: TmuxSizingState?
    /// Additive: absent on pre-multi-session values — read through
    /// `effectiveSessions`, which synthesizes the attached alias.
    public var sessions: [TmuxSessionState]?

    public init(rev: UInt64, target: String, session: String,
                structure: TmuxStructureSnapshot,
                sizing: TmuxSizingState? = nil,
                sessions: [TmuxSessionState]? = nil) {
        self.rev = rev
        self.target = target
        self.session = session
        self.structure = structure
        self.sizing = sizing
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case rev, target, session, structure, sizing, sessions
    }

    // Additive-lenient by hand: the ORIGINAL four fields stay required (the
    // daemon always writes them; anything without them is not a structure
    // state), while the additive fields simply read absent on old values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rev = try c.decode(UInt64.self, forKey: .rev)
        target = try c.decode(String.self, forKey: .target)
        session = try c.decode(String.self, forKey: .session)
        structure = try c.decode(TmuxStructureSnapshot.self, forKey: .structure)
        sizing = try c.decodeIfPresent(TmuxSizingState.self, forKey: .sizing)
        sessions = try c.decodeIfPresent([TmuxSessionState].self, forKey: .sessions)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rev, forKey: .rev)
        try c.encode(target, forKey: .target)
        try c.encode(session, forKey: .session)
        try c.encode(structure, forKey: .structure)
        try c.encodeIfPresent(sizing, forKey: .sizing)
        try c.encodeIfPresent(sessions, forKey: .sessions)
    }

    /// Every session on the server. Prefers the additive `sessions` array;
    /// an old value (or a synthesized one) reads as the attached pair alone.
    /// Empty when the server has no sessions (killSession took the last one).
    public var effectiveSessions: [TmuxSessionState] {
        if let sessions { return sessions }
        guard !session.isEmpty else { return [] }
        return [TmuxSessionState(id: "", name: session, attached: true,
                                 structure: structure)]
    }

    /// The named session's row, nil when the server doesn't have it.
    public func sessionState(named name: String) -> TmuxSessionState? {
        effectiveSessions.first { $0.name == name }
    }
}

/// One session's row in the mirror (`tmuxSessionState`, tmuxpane.go). `id`
/// is the tmux session id ("$N"), stable across renames; `attached` marks
/// the ONE session the daemon's control client is on — the session whose
/// panes stream %output.
public struct TmuxSessionState: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var attached: Bool
    public var structure: TmuxStructureSnapshot

    public init(id: String, name: String, attached: Bool = false,
                structure: TmuxStructureSnapshot) {
        self.id = id
        self.name = name
        self.attached = attached
        self.structure = structure
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, attached, structure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        attached = try c.decodeIfPresent(Bool.self, forKey: .attached) ?? false
        structure = try c.decodeIfPresent(TmuxStructureSnapshot.self, forKey: .structure)
            ?? TmuxStructureSnapshot(windows: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !id.isEmpty { try c.encode(id, forKey: .id) }
        try c.encode(name, forKey: .name)
        if attached { try c.encode(attached, forKey: .attached) }
        try c.encode(structure, forKey: .structure)
    }
}

/// The session-size authority block (`tmuxhost.Sizing`): policy is
/// latest|pinned|smallest; `ownerDevice` is the pinning device's display
/// label (empty otherwise); cols×rows is the resolved governing size.
public struct TmuxSizingState: Codable, Sendable, Equatable {
    public var policy: String
    public var ownerDevice: String
    public var cols: Int
    public var rows: Int

    public init(policy: String, ownerDevice: String = "", cols: Int = 0, rows: Int = 0) {
        self.policy = policy
        self.ownerDevice = ownerDevice
        self.cols = cols
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case policy
        case ownerDevice = "owner_device"
        case cols, rows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.decodeIfPresent(String.self, forKey: .policy) ?? ""
        ownerDevice = try c.decodeIfPresent(String.self, forKey: .ownerDevice) ?? ""
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 0
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
    }
}

/// Wire mirror of tmuxcm.StructureSnapshot. Pane ids serialize as BARE
/// ints (`%5` → 5) — the Go side's convention, kept exactly.
public struct TmuxStructureSnapshot: Codable, Sendable, Equatable {
    public var windows: [TmuxSnapshotWindow]

    public init(windows: [TmuxSnapshotWindow]) { self.windows = windows }
}

/// One window's shape. `layout` is tmux's own layout string (braces and
/// all); the projection prefers the per-pane geometry in `details` and
/// keeps the string untouched for a future faithful translator.
public struct TmuxSnapshotWindow: Codable, Sendable, Equatable {
    public var index: Int
    public var name: String
    public var layout: String
    /// `#{window_active}` — the session's current window. Additive
    /// (omitempty): old stashes and pre-5.5 mirror values simply read
    /// false; the daemon's mirror always carries it, so a client can read
    /// WHICH window is current instead of guessing.
    public var active: Bool
    public var panes: [Int]
    /// Per-pane reading matching `panes`; empty when the source didn't
    /// carry one (the daemon's mirror does).
    public var details: [TmuxSnapshotPane]

    public init(index: Int, name: String, layout: String = "", active: Bool = false,
                panes: [Int], details: [TmuxSnapshotPane] = []) {
        self.index = index
        self.name = name
        self.layout = layout
        self.active = active
        self.panes = panes
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case index, name, layout, active, panes, details
    }

    // Lenient by hand: the Go side omits empty fields (`omitempty`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? ""
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        panes = try c.decodeIfPresent([Int].self, forKey: .panes) ?? []
        details = try c.decodeIfPresent([TmuxSnapshotPane].self, forKey: .details) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(name, forKey: .name)
        if !layout.isEmpty { try c.encode(layout, forKey: .layout) }
        if active { try c.encode(active, forKey: .active) }
        try c.encode(panes, forKey: .panes)
        if !details.isEmpty { try c.encode(details, forKey: .details) }
    }
}

/// One pane's reading: what the chrome renders (title/active/zoom) and the
/// geometry the layout projection is built from. All of it is tmux's
/// listing — never client-side state. NO `pane_current_command` field, on
/// purpose and matching the daemon exactly: process introspection flaps
/// (a starting /bin/sh reports sh, then bash), and a flapping field inside
/// change-detected structure would mint spurious mirror revs (tmuxcm
/// SnapshotPane). Command identity for state detection is a stage-2
/// reading with its own channel.
public struct TmuxSnapshotPane: Codable, Sendable, Equatable {
    public var id: Int
    public var title: String
    public var width: Int
    public var height: Int
    public var x: Int
    public var y: Int
    public var active: Bool
    public var zoomed: Bool

    public init(id: Int, title: String = "", width: Int, height: Int,
                x: Int, y: Int, active: Bool = false, zoomed: Bool = false) {
        self.id = id
        self.title = title
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.active = active
        self.zoomed = zoomed
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, width, height, x, y, active, zoomed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        x = try c.decodeIfPresent(Int.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Int.self, forKey: .y) ?? 0
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        zoomed = try c.decodeIfPresent(Bool.self, forKey: .zoomed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !title.isEmpty { try c.encode(title, forKey: .title) }
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        if active { try c.encode(active, forKey: .active) }
        if zoomed { try c.encode(zoomed, forKey: .zoomed) }
    }
}

public enum TmuxStructureDecoding {
    /// The statekv key the daemon mirrors a target's structure under.
    public static func statekvKey(target: String) -> String {
        "tmux/\(target)/structure"
    }

    /// Decode a statekv payload (the transport already unwraps statekv's
    /// base64; this takes the JSON bytes). nil for anything that isn't a
    /// structure state.
    public static func decode(_ json: Data) -> TmuxStructureState? {
        try? JSONDecoder().decode(TmuxStructureState.self, from: json)
    }
}

// MARK: - Projection (tmux structure → workspace vocabulary)

extension TmuxStructureState {
    /// The preset id stamped on projected tmux panes. A placeholder, not a
    /// resolvable ACP preset — `PaneEntry`'s preset vocabulary is
    /// ACP-shaped, and pane-kind-aware preset resolution is stage-2 work.
    package static let tmuxPresetID = "tmux"

    /// Project the ATTACHED session as a workspace (the pre-multi-session
    /// alias; see `workspaceEntry(entryID:sessionName:)`).
    package func workspaceEntry(entryID: Int) -> AgentWorkspaceStore.WorkspaceEntry? {
        Self.workspaceEntry(entryID: entryID, target: target,
                            session: session, structure: structure)
    }

    /// Project a NAMED session's structure as a workspace — the
    /// multi-session read path (every session on the server is in
    /// `effectiveSessions`, not just the attached one).
    package func workspaceEntry(entryID: Int, sessionName: String)
        -> AgentWorkspaceStore.WorkspaceEntry? {
        guard let row = sessionState(named: sessionName) else { return nil }
        return Self.workspaceEntry(entryID: entryID, target: target,
                                   session: row.name, structure: row.structure)
    }

    /// Project one session's snapshot as a workspace: every window's panes
    /// in window-then-pane order (the Focus list), the CURRENT window's
    /// geometry as the layout tree, ids carried through as `%N`'s number.
    ///
    /// The current window is the one whose `active` flag the mirror set
    /// (`#{window_active}`); values that predate the flag fall back to the
    /// lowest-indexed window. `entryID` is the store slot — the snapshot
    /// has no numeric session id of its own.
    package static func workspaceEntry(entryID: Int, target: String, session: String,
                                       structure: TmuxStructureSnapshot)
        -> AgentWorkspaceStore.WorkspaceEntry? {
        let windows = structure.windows.sorted { $0.index < $1.index }
        guard let parallel = windows.first(where: \.active) ?? windows.first else { return nil }

        var paneEntries: [AgentWorkspaceStore.PaneEntry] = []
        for window in windows {
            for pane in window.orderedDetails {
                paneEntries.append(AgentWorkspaceStore.PaneEntry(
                    id: pane.id,
                    kind: .tmux,
                    presetID: Self.tmuxPresetID,
                    customPreset: nil,
                    // The mirror carries no pane_current_path (yet) — cwd
                    // is a reading the daemon would have to add.
                    cwd: "",
                    title: pane.title.isEmpty ? nil : pane.title,
                    instanceID: TmuxVirtualInstanceID(
                        target: target, pane: TmuxPaneID(pane.id)).raw,
                    acpSessionID: nil,
                    // The mirror deliberately omits pane_current_command
                    // (see TmuxSnapshotPane) — nothing honest to put here.
                    startCommand: nil))
            }
        }
        guard !paneEntries.isEmpty else { return nil }

        let parallelPanes = parallel.orderedDetails
        let cols = max(parallelPanes.map { $0.x + $0.width }.max() ?? 1, 1)
        let rows = max(parallelPanes.map { $0.y + $0.height }.max() ?? 1, 1)
        let layout = Self.layoutProjection(of: parallelPanes)
            ?? LayoutTree.tiledPreset(panes: parallelPanes.map(\.id),
                                      cols: cols, rows: rows)
        guard let layout else { return nil }

        let active = parallelPanes.first(where: \.active) ?? parallelPanes[0]
        // window_zoomed_flag is per-window (every pane reports it); the
        // zoomed pane itself is the active one.
        let zoomed = parallelPanes.contains(where: \.zoomed) ? active.id : nil

        return AgentWorkspaceStore.WorkspaceEntry(
            id: entryID, name: session, panes: paneEntries,
            layout: layout, activePane: active.id, zoomedPane: zoomed,
            cols: cols, rows: rows)
    }

    // MARK: Geometry → LayoutTree (guillotine recovery)

    /// Rebuild a split tree from the mirror's pane rects. tmux geometry is
    /// always a guillotine partition (every split leaves a full-length
    /// divider line), so recursing on clean cuts reconstructs it exactly;
    /// `LayoutTree.resized` then renormalizes cells to the unit canvas,
    /// absorbing the one-cell dividers. nil when the rects don't partition
    /// (defensive — the caller falls back to the tiled grid).
    static func layoutProjection(of panes: [TmuxSnapshotPane]) -> LayoutTree.Node? {
        guard let node = cellNode(of: panes) else { return nil }
        return LayoutTree.resized(node, w: 0, h: 0)
    }

    /// The tree in absolute tmux cells (pre-normalization).
    private static func cellNode(of panes: [TmuxSnapshotPane]) -> LayoutTree.Node? {
        guard let first = panes.first else { return nil }
        if panes.count == 1 {
            return .leaf(id: first.id, w: Double(first.width), h: Double(first.height),
                         x: Double(first.x), y: Double(first.y))
        }
        let minX = panes.map(\.x).min() ?? 0
        let minY = panes.map(\.y).min() ?? 0
        let maxX = panes.map { $0.x + $0.width }.max() ?? 0
        let maxY = panes.map { $0.y + $0.height }.max() ?? 0
        if let groups = cutGroups(panes, alongX: true) {
            let children = groups.compactMap(cellNode(of:))
            guard children.count == groups.count else { return nil }
            return .hsplit(w: Double(maxX - minX), h: Double(maxY - minY),
                           x: Double(minX), y: Double(minY), children: children)
        }
        if let groups = cutGroups(panes, alongX: false) {
            let children = groups.compactMap(cellNode(of:))
            guard children.count == groups.count else { return nil }
            return .vsplit(w: Double(maxX - minX), h: Double(maxY - minY),
                           x: Double(minX), y: Double(minY), children: children)
        }
        return nil
    }

    /// Partition panes at every clean full-length cut along one axis.
    /// A cut at `c` is clean when every pane ends at or before it, or
    /// starts past its one-cell divider (`c + 1`). ≥2 groups or nil.
    private static func cutGroups(_ panes: [TmuxSnapshotPane],
                                  alongX: Bool) -> [[TmuxSnapshotPane]]? {
        func end(_ p: TmuxSnapshotPane) -> Int { alongX ? p.x + p.width : p.y + p.height }
        func start(_ p: TmuxSnapshotPane) -> Int { alongX ? p.x : p.y }

        let candidates = Set(panes.map(end)).sorted()
        guard let last = candidates.last else { return nil }
        var groups: [[TmuxSnapshotPane]] = []
        var remaining = panes
        for cut in candidates where cut < last {
            let before = remaining.filter { end($0) <= cut }
            let after = remaining.filter { start($0) >= cut + 1 }
            guard !before.isEmpty, !after.isEmpty,
                  before.count + after.count == remaining.count else { continue }
            groups.append(before)
            remaining = after
        }
        guard !groups.isEmpty else { return nil }
        groups.append(remaining)
        return groups
    }
}

extension TmuxSnapshotWindow {
    /// The per-pane readings in `panes` order; ids alone are synthesized
    /// into zero-rect readings when the source carried no details (an old
    /// Swift-era stash) so downstream code has one shape to walk.
    public var orderedDetails: [TmuxSnapshotPane] {
        guard !details.isEmpty else {
            return panes.map { TmuxSnapshotPane(id: $0, width: 0, height: 0, x: 0, y: 0) }
        }
        let byID = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return panes.compactMap { byID[$0] }
    }
}
