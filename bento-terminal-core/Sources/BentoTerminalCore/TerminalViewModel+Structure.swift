import Foundation

/// Bento's two view modes. The user thinks in exactly two shapes:
///
///   Tiled (Parallel) — the layout tree, every agent at once.
///   List (Focus)     — one pane full-screen, switch fast.
///
/// Windows are gone, so the mode is a PURE VIEW PREFERENCE: switching is a
/// zero-structure, always-lossless presentation toggle, remembered per
/// session. The structure itself is one flat set of panes in one layout
/// tree, owned by `AgentWorkspaceStore`.
@MainActor
public extension TerminalViewModel {
    // MARK: - Derived structure & mode

    /// The session's structural shape, derived purely from `sessionPanes`.
    var sessionStructure: SessionStructure {
        sessionPanes.count > 1 ? .tiled : .degenerate
    }

    /// Apply the remembered view-mode preference. Called after every pane
    /// refresh (keeps the historical call sites).
    internal func recomputeSessionMode() {
        loadModePreferenceIfNeeded()
        let mode = savedModePreference ?? .tiled
        if mode != sessionMode { sessionMode = mode }
    }

    /// Per-session persistence key for the view mode.
    private var modePreferenceKey: String {
        "bento_view_mode_\(activeSessionName ?? host.name)"
    }

    /// One-shot read of the session's remembered mode.
    private func loadModePreferenceIfNeeded() {
        guard !modePreferenceLoaded else { return }
        modePreferenceLoaded = true
        if let raw = UserDefaults.standard.string(forKey: modePreferenceKey),
           let saved = SessionViewMode(rawValue: raw) {
            savedModePreference = saved
        }
    }

    /// Switch the view mode. A pure presentation toggle — zero structure
    /// changes, always lossless, always succeeds. (`force` kept for call-site
    /// compatibility; there is nothing left to warn about.)
    @discardableResult
    func setMode(_ mode: SessionViewMode, force: Bool = false) async -> Bool {
        savedModePreference = mode
        UserDefaults.standard.set(mode.rawValue, forKey: modePreferenceKey)
        if sessionMode != mode { sessionMode = mode }
        return true
    }

    // MARK: - Naming & status

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
            if case .awaitingInput = state { return .awaiting }
            if state == .working { return .working }
        }
        if paneDoneUnseen[paneID] == true { return .doneUnseen }
        return .idle
    }

    // MARK: - Creation (identical in both modes; only the landing differs)

    /// The active pane's working directory (nil if unknown). Seeds the New
    /// Pane / Split directory picker so confirming immediately reuses the
    /// current folder, or the user can navigate elsewhere.
    func activePaneWorkingDirectory() async -> String? {
        guard let id = activePaneID else { return nil }
        return workspace?.paneCwd(id.raw)
    }

    /// List (Focus) mode: open a new pane seeded per `seed`. (The name
    /// survives from the window era — every "window" is a pane now.)
    func newFocusPane(_ seed: PaneSeed) async {
        guard let workspace, attached, let session = activeSessionName else { return }
        let (path, command) = resolveSeed(seed)
        DIAG("[DUP] newFocusPane seed=\(seed) path=\(path ?? "nil") cmd=\(command ?? "nil") panesBefore=\(sessionPanes.map { "\($0.id)" }.joined(separator: ","))")
        _ = workspace.newPane(session: session, cwd: path, command: command)
        await refreshPanes()
    }

    /// Tiled mode: split the active pane, seeded per `seed` (creation parity
    /// with List — duplicate current / specify path+command).
    func splitPane(horizontal: Bool, seed: PaneSeed) async {
        guard let workspace, attached, let session = activeSessionName else { return }
        let (path, command) = resolveSeed(seed)
        guard let target = activePaneID?.raw ?? workspace.session(session)?.activePane else { return }
        DIAG("[DUP] splitPane target=\(target) h=\(horizontal) path=\(path ?? "nil") cmd=\(command ?? "nil")")
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
            guard let workspace, let pane = activePaneID else { return (nil, nil) }
            let path = workspace.paneCwd(pane.raw)
            if let start = blankToNil(workspace.paneStartCommand(pane.raw)) {
                return (path, start)
            }
            let current = blankToNil(workspace.paneCurrentCommand(pane.raw))
            let cmd = current.flatMap { Self.isShellName($0) ? nil : $0 }
            return (path, cmd)
        }
    }

    /// Whether a command value is just a login/interactive shell (so
    /// "duplicate" should open the default agent, not re-run the shell).
    private static func isShellName(_ command: String) -> Bool {
        let name = command.hasPrefix("-") ? String(command.dropFirst()) : command
        return ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh"].contains(name)
    }

    private func blankToNil(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // MARK: - Cross-session moves

    /// Move a pane out of this session into `target`. The pane's agent
    /// travels untouched — pane IDs are store-global. The one landing
    /// semantic: the target's active cell splits. Creates the target session
    /// when it doesn't exist yet ("New Session…" funnels through here), and
    /// kills the fresh session's placeholder pane afterwards so the target
    /// holds exactly the moved pane.
    ///
    /// Moving the session's LAST pane destroys the source under this client,
    /// so the client FOLLOWS: adopt the target first, then move. The source
    /// dies quietly behind us and the view is already where the pane lands.
    @discardableResult
    func movePane(_ paneID: PaneID, toSession target: String,
                  landing: MoveLanding = .auto) async -> MoveResult {
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace, attached, !name.isEmpty, name != activeSessionName
        else { return .failed }

        // A fresh session is born with a default-agent placeholder pane;
        // remember it so exactly the moved pane remains after the move.
        var placeholder: Int?
        if workspace.session(name) == nil {
            workspace.createSession(name)
            guard workspace.session(name) != nil else { return .failed }
            placeholder = workspace.session(name)?.panes.first?.id
        }

        let isLast = sessionPanes.count <= 1
        if isLast {
            // Source about to die → follow BEFORE the move.
            activeSessionName = name
            workspace.ensureRuntimes(session: name)
        }

        guard workspace.movePane(paneID.raw, toSession: name) else {
            dlog("movePane \(paneID): move → \(name) failed")
            return .failed
        }
        if let placeholder {
            workspace.killPane(placeholder)
        }
        DIAG("[MODE] movePane \(paneID) → session '\(name)' follow=\(isLast)")

        await refreshPanes()
        await refreshSessions()   // warm the list for the next menu open
        return .moved
    }
}
