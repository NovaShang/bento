// Ported from frozen TerminalViewModel+Structure.swift @ 8fa54b6^; data layer swapped, UI verbatim.
//
// The two-mode model, its derived readings and the structure transforms,
// re-sourced: shapes are read off the daemon's mirror (this VM's session row
// plus every OTHER session's row — the frozen server-side probes became
// local reads), transforms travel as structure verbs. Where the frozen
// implementation kept server-side memory in tmux options (@bento_structure /
// @bento_mode) the daemon has no set-option verb yet — those memories are
// local + flagged, and merge falls back to the historical applyTiled shape.

import Foundation
import BentoTerminalPane
import BentoTmuxPane
import BentoWorkbench

/// Bento's two-mode model. The user thinks in exactly two shapes:
///
///   Tiled — ONE window, many panes: see every agent at once.
///   List  — many windows, ONE pane each: focus one, switch fast.
///
/// The mode is a READING of the tmux session's structure, never client-side
/// state, and every in-app operation preserves its mode's invariant — inside
/// Bento you cannot produce any third shape. Mixed structures (several
/// windows, some multi-pane) only appear when attaching a session built
/// outside Bento; they read as Tiled (of the current window) and flattening
/// them into List is the one mode switch that asks for confirmation.
public enum TmuxSessionMode: String, Equatable, Sendable {
    case tiled, list
}

/// The raw structural shape (internal reading behind `sessionMode`).
public enum TmuxSessionStructure: Equatable, Sendable {
    /// One window, one pane — both modes coincide.
    case degenerate
    /// One window, many panes.
    case tiled
    /// Many windows, every one a single pane.
    case list
    /// Many windows, at least one holding multiple panes — external sessions
    /// only; reads as Tiled, flattens to List with confirmation.
    case hierarchical
}

/// A window row/tab's visual status — the state aggregate plus the
/// "done, unseen" layer that isn't a `PaneState`. See `windowStatus`.
public enum WindowDisplayStatus: Equatable, Sendable {
    case idle       // nothing running / seen — no accent
    case working    // an agent is running — blue
    case awaiting   // an agent needs input — amber
    case doneUnseen // an agent finished while unfocused — green (✓)

    /// Stable signature for the toolbar strip: the segment group is rebuilt
    /// whenever a title OR a dot changes, and mutating a live group's images
    /// doesn't reliably re-render.
    public var dotKey: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .awaiting: return "awaiting"
        case .doneUnseen: return "doneUnseen"
        }
    }
}

/// Where a cross-session move lands in the target session. `.auto` derives
/// it from the target's shape (Parallel → its current window, Focus → a new
/// window); the explicit cases are what the UI passes back after the
/// "unsettled target" prompt.
public enum MoveLanding: Sendable, Equatable {
    case auto, joinCurrentWindow, newWindow
}

/// Outcome of a cross-session move. `.needsLandingChoice` means nothing was
/// moved: the target is neither clearly Parallel nor Focus (a fresh 1×1 with
/// no remembered mode, or a mixed external structure) — ask the user and
/// call again with an explicit `MoveLanding`.
public enum MoveResult: Sendable, Equatable {
    case moved, needsLandingChoice, failed
}

/// How a new window (List) or pane (Tiled) gets seeded — the two creation
/// paths, identical in both modes.
public enum WindowSeed: Sendable {
    /// Same working directory and start command as the current pane.
    case duplicateCurrent
    /// Explicit working directory and/or command (nil command = plain shell).
    case custom(path: String?, command: String?)
}

@MainActor
public extension TerminalViewModel {
    // MARK: - Derived structure & mode

    /// The session's structural shape, derived purely from `sessionPanes`.
    var sessionStructure: TmuxSessionStructure {
        let byWindow = panesByWindow
        if byWindow.count <= 1 {
            return (sessionPanes.count > 1) ? .tiled : .degenerate
        }
        return byWindow.values.contains { $0.count > 1 } ? .hierarchical : .list
    }

    /// True when the structure came from outside Bento (windows AND splits) —
    /// the UI warns before flattening it into List.
    var isMixedStructure: Bool {
        panesByWindow.count > 1 && panesByWindow.values.contains { $0.count > 1 }
    }

    /// Recompute `sessionMode` from structure (+ the remembered preference
    /// for the degenerate case). Called after every mirror push.
    internal func recomputeSessionMode() {
        loadModePreferenceIfNeeded()
        let byWindow = panesByWindow
        let mode: TmuxSessionMode
        if byWindow.count > 1 {
            // Many windows: List — unless it's a mixed external structure,
            // which reads as Tiled (of the current window).
            mode = isMixedStructure ? .tiled : .list
        } else if sessionPanes.count > 1 {
            mode = .tiled
        } else {
            // Degenerate: Bento's default face is Tiled; an explicit List
            // choice sticks so closing down to one window doesn't yank the
            // user out of their List workflow (and its "+" affordance).
            mode = savedModePreference ?? .tiled
        }
        if mode != sessionMode { sessionMode = mode }
    }

    /// One-shot read of the session's remembered mode. FLAGGED data-layer
    /// difference: the frozen product kept this in the server-side
    /// `@bento_mode` tmux option (shared by every device); the daemon has no
    /// set-option verb yet, so this device's UserDefaults remembers instead.
    private func loadModePreferenceIfNeeded() {
        guard usingTmux, !modePreferenceLoaded else { return }
        modePreferenceLoaded = true
        if let session = activeTmuxSessionName,
           let raw = UserDefaults.standard.string(forKey: Self.modeOption + "." + session),
           let saved = TmuxSessionMode(rawValue: raw) {
            savedModePreference = saved
            recomputeSessionMode()
        }
    }

    /// Switch the session's mode — THE structure transformation. Lossless and
    /// unconfirmed by design, with one exception: flattening a mixed external
    /// structure into List can't be exactly restored, so it requires
    /// `force: true` (the UI warns first). Returns false when it declined.
    @discardableResult
    func setMode(_ mode: TmuxSessionMode, force: Bool = false) async -> Bool {
        guard usingTmux else { return false }
        if mode == .list, isMixedStructure, !force { return false }

        switch (sessionStructure, mode) {
        case (.tiled, .list), (.hierarchical, .list):
            await spreadToList()
        case (.list, .tiled), (.hierarchical, .tiled):
            await mergeToTiled()
        default:
            break   // degenerate or already in shape — presentation only
        }

        savedModePreference = mode
        if let session = activeTmuxSessionName {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeOption + "." + session)
        }
        recomputeSessionMode()
        return true
    }

    // MARK: - Grouping & naming

    /// Session panes grouped by window, in mirror order (window order, then
    /// pane order within each window).
    var panesByWindow: [TmuxWindowID: [Pane]] {
        var result: [TmuxWindowID: [Pane]] = [:]
        for pane in sessionPanes {
            guard let win = pane.windowID else { continue }
            result[win, default: []].append(pane)
        }
        return result
    }

    /// Panes of one window, in pane-index order.
    func panes(in windowID: TmuxWindowID) -> [Pane] {
        sessionPanes.filter { $0.windowID == windowID }
    }

    /// The LIVE display name for a window, prefixed with tmux's own
    /// `#{window_index}` so the label reads exactly like `list-windows` and can
    /// be carried straight to `select-window -t <index>`. A single-pane window
    /// is named by its pane's title (what's actually running — auto-updated); a
    /// multi-pane window falls back to the tmux window name.
    func windowDisplayName(_ windowID: TmuxWindowID) -> String {
        let window = windows.first { $0.id == windowID }
        let body = windowBodyName(windowID, window: window)
        guard let index = window?.index else { return body }
        return "\(index):\(body)"
    }

    /// `windowDisplayName` without the index prefix — for places that show the
    /// index separately (or have no room for it).
    func windowBodyName(_ windowID: TmuxWindowID) -> String {
        windowBodyName(windowID, window: windows.first { $0.id == windowID })
    }

    private func windowBodyName(_ windowID: TmuxWindowID, window: TmuxWindow?) -> String {
        let winPanes = panes(in: windowID)
        let windowName = window?.name.trimmingCharacters(in: .whitespaces)
        if winPanes.count > 1 {
            return windowName.flatMap { $0.isEmpty ? nil : $0 } ?? "\(winPanes.count) panes"
        }
        let pane = winPanes.first
        return [pane?.title, pane?.currentCommand, windowName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "shell"
    }

    /// Aggregate agent state for a window's row/tab, highest priority first:
    /// any pane awaiting input → awaiting; else any working → working; else
    /// idle. Reads the `paneStates` cache that `updatePaneStates` fills for
    /// every session pane through the one detection pipeline.
    func windowState(_ windowID: TmuxWindowID) -> PaneState {
        var sawWorking = false
        for pane in panes(in: windowID) {
            guard let state = paneStates[pane.id] else { continue }
            if case .awaitingInput = state { return state }
            if state == .working { sawWorking = true }
        }
        return sawWorking ? .working : .idle
    }

    /// A window's display status, richest first — the same aggregate as
    /// `windowState` PLUS the "done, unseen" layer, which isn't a PaneState.
    /// Priority: awaiting → working → done → idle.
    func windowStatus(_ windowID: TmuxWindowID) -> WindowDisplayStatus {
        var sawWorking = false
        var sawDone = false
        for pane in panes(in: windowID) {
            if let state = paneStates[pane.id] {
                if case .awaitingInput = state { return .awaiting }
                if state == .working { sawWorking = true }
            }
            if paneDoneUnseen[pane.id] == true { sawDone = true }
        }
        if sawWorking { return .working }
        if sawDone { return .doneUnseen }
        return .idle
    }

    // MARK: - Creation (identical in both modes; only the landing differs)

    /// The active pane's live working directory (nil if unknown). Seeds the New
    /// Window / Split directory picker. FLAGGED: the mirror carries no
    /// pane_current_path reading yet, so this answers nil (pickers fall back
    /// to home) until the daemon grows the channel.
    func activePaneWorkingDirectory() async -> String? {
        guard let id = activePaneID,
              let vm = paneViewModels.first(where: { $0.paneID == id }) else { return nil }
        return await vm.currentWorkingDirectory()
    }

    /// List mode: open a new window seeded per `seed`.
    func newListWindow(_ seed: WindowSeed) async {
        guard usingTmux, let session = activeTmuxSessionName else { return }
        let (path, command) = await resolveSeed(seed)
        DIAG("[DUP] newListWindow seed=\(seed) path=\(path ?? "nil") cmd=\(String(describing: command)) panesBefore=\(sessionPanes.map { "\($0.id)" }.joined(separator: ","))")
        do {
            _ = try await link.applyAwait(.newPane(session: session, cwd: path, command: command))
        } catch {
            dlog("newListWindow failed: \(error)")
        }
    }

    /// Tiled mode: split the active pane, seeded per `seed` (creation parity
    /// with List — duplicate current / specify path+command).
    func splitPane(horizontal: Bool, seed: WindowSeed) async {
        guard usingTmux, let session = activeTmuxSessionName,
              let target = activePaneID else { return }
        let (path, command) = await resolveSeed(seed)
        DIAG("[DUP] splitPane target=\(target) h=\(horizontal) path=\(path ?? "nil") cmd=\(String(describing: command)) panesBefore=\(sessionPanes.map { "\($0.id)" }.joined(separator: ","))")
        do {
            _ = try await link.applyAwait(.splitPane(
                session: session, target: target.raw, horizontal: horizontal,
                cwd: path, command: command))
        } catch {
            dlog("splitPane(seed) failed: \(error)")
        }
    }

    /// Resolve a seed to (path, command). FLAGGED data-layer gap: "duplicate
    /// current" read the active pane's live cwd and program from tmux
    /// (`#{pane_current_path}` / `#{pane_start_command}` /
    /// `#{pane_current_command}`); the mirror deliberately carries none of
    /// those readings yet, so duplication degrades to a plain shell in the
    /// server-default directory until the daemon grows the channel.
    private func resolveSeed(_ seed: WindowSeed) async -> (String?, String?) {
        switch seed {
        case .custom(let path, let command):
            return (blankToNil(path), blankToNil(command))
        case .duplicateCurrent:
            guard activePaneID != nil else { return (nil, nil) }
            let path = await activePaneWorkingDirectory()
            return (path, nil)
        }
    }

    private func blankToNil(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // MARK: - Structure transforms (internals of setMode)

    /// The frozen structure-memory option names, kept for the local
    /// remembered-mode key (`@bento_mode`); the structure snapshot itself has
    /// no daemon home yet (no set-option verb — flagged), so merge falls back
    /// to the historical applyTiled shape.
    private static let modeOption = "@bento_mode"

    /// tiled → list: break every pane out into its own window (processes
    /// untouched). Break-pane travels as the daemon's movePane verb with the
    /// pane's OWN session as the destination — the pane moves into its own
    /// window in place.
    @discardableResult
    internal func spreadToList() async -> Bool {
        guard usingTmux, let session = activeTmuxSessionName else { return false }
        let byWindow = panesByWindow
        let multiPane = byWindow.filter { $0.value.count > 1 }
        guard !multiPane.isEmpty else { return false }

        for (_, winPanes) in multiPane {
            // Break all but the first, deliberately WITHOUT a name (tmux's
            // automatic-rename keeps working; see the frozen note).
            for pane in winPanes.dropFirst() {
                do {
                    _ = try await link.applyAwait(.movePane(pane: pane.id.raw, toSession: session))
                } catch {
                    dlog("spreadToList: break-pane \(pane.id) failed: \(error)")
                }
            }
        }
        return true
    }

    /// Leaving Focus: gather every pane into one window, evened out.
    /// FLAGGED: the frozen implementation restored the exact remembered
    /// window/pane shape from `@bento_structure`; that memory has no daemon
    /// home yet, so this is the frozen fallback path (gather + tiled), which
    /// was also its behavior with nothing remembered.
    @discardableResult
    internal func mergeToTiled() async -> Bool {
        guard usingTmux, let session = activeTmuxSessionName else { return false }
        guard panesByWindow.count > 1 else { return false }
        do {
            _ = try await link.applyAwait(.applyTiled(session: session))
            return true
        } catch {
            dlog("mergeToTiled: applyTiled failed: \(error)")
            return false
        }
    }

    // MARK: - Cross-session moves

    /// Move a pane out of this session into `target`. The pane's process and
    /// scrollback travel untouched — pane IDs are server-global. The LANDING
    /// respects the target's mode (see `moveToSession`): a Parallel target
    /// absorbs it into its current window, a Focus target gets a new window,
    /// an unsettled target returns `.needsLandingChoice` so the UI can ask.
    /// Creates the target session when it doesn't exist yet ("New Session…"
    /// funnels through here), and kills the fresh session's placeholder
    /// shell window afterwards so the target holds exactly the moved pane.
    ///
    /// Moving the session's LAST pane would destroy the source session under
    /// this window — so the window FOLLOWS: ensure the target first, then
    /// move. The source dies quietly behind us and the view is already where
    /// the pane lands.
    @discardableResult
    func movePane(_ paneID: TmuxPaneID, toSession target: String,
                  landing: MoveLanding = .auto) async -> MoveResult {
        await moveToSession(
            target, isLast: sessionPanes.count <= 1, landing: landing,
            kind: "movePane \(paneID)",
            movedPane: paneID,
            join: { [weak self] dockTarget in
                guard let self else { return false }
                _ = try await self.link.applyAwait(.dockPane(
                    source: paneID.raw, at: dockTarget, horizontal: true, before: false))
                return true
            },
            asWindow: { [weak self] session in
                guard let self else { return false }
                _ = try await self.link.applyAwait(.movePane(pane: paneID.raw, toSession: session))
                return true
            })
    }

    /// Move a whole window into another session: the Focus/List window row's
    /// counterpart of `movePane`, with the same landing rules — a Focus
    /// window IS one pane, so a Parallel target absorbs that pane into its
    /// current window. FLAGGED: a multi-pane window (external/mixed
    /// structures only) travelled intact via move-window in the frozen
    /// product; the daemon has no window-move verb yet, so its panes move
    /// one by one (each landing as its own window in the target).
    @discardableResult
    func moveWindow(_ windowID: TmuxWindowID, toSession target: String,
                    landing: MoveLanding = .auto) async -> MoveResult {
        let winPanes = panes(in: windowID)
        let soleID = winPanes.count == 1 ? winPanes.first?.id : nil
        return await moveToSession(
            target, isLast: windows.count <= 1,
            landing: soleID == nil ? .newWindow : landing,
            kind: "moveWindow \(windowID)",
            movedPane: soleID,
            join: { [weak self] dockTarget in
                guard let self, let soleID else { return false }
                _ = try await self.link.applyAwait(.dockPane(
                    source: soleID.raw, at: dockTarget, horizontal: true, before: false))
                return true
            },
            asWindow: { [weak self] session in
                guard let self else { return false }
                for pane in winPanes {
                    _ = try await self.link.applyAwait(.movePane(pane: pane.id.raw, toSession: session))
                }
                return true
            })
    }

    /// Shared plumbing for the two moves: create-if-missing, resolve the
    /// landing from the target's shape, follow when the source would die,
    /// run the move, clean a fresh target's placeholder, resync.
    private func moveToSession(_ target: String,
                               isLast: Bool,
                               landing: MoveLanding,
                               kind: String,
                               movedPane: TmuxPaneID?,
                               join: (Int) async throws -> Bool,
                               asWindow: (String) async throws -> Bool) async -> MoveResult {
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usingTmux, !name.isEmpty, name != activeTmuxSessionName else { return .failed }

        let created: Bool
        if link.sessions.contains(where: { $0.name == name }) {
            created = false
        } else {
            do {
                _ = try await link.applyAwait(.createSession(name: name, cwd: nil))
                created = true
            } catch {
                dlog("\(kind): createSession \(name) failed: \(error)")
                return .failed
            }
        }

        var resolved = landing
        if created {
            resolved = .newWindow
        } else if landing == .auto {
            switch probeSessionShape(name) {
            case .tiled: resolved = .joinCurrentWindow
            case .list: resolved = .newWindow
            case .unsettled: return .needsLandingChoice
            }
        }

        // Source about to die → follow BEFORE the move, while this window
        // still has a session under it (the ensure is the switch-client).
        if isLast {
            do {
                try await link.ensure(session: name)
            } catch {
                dlog("\(kind): follow (ensure \(name)) failed: \(error)")
                return .failed
            }
        }

        var landedAsJoin = false
        if resolved == .joinCurrentWindow, let dockTarget = activePane(ofSession: name) {
            do {
                landedAsJoin = try await join(dockTarget)
            } catch {
                // Same failure mode as merge: the target pane may be too
                // small to split. Even the target's window out and retry once.
                _ = try? await link.applyAwait(.applyTiled(session: name))
                landedAsJoin = (try? await join(dockTarget)) ?? false
                if !landedAsJoin {
                    dlog("\(kind): join → \(name) refused (\(error)) — landing as window")
                }
            }
        }
        if !landedAsJoin {
            do {
                _ = try await asWindow(name)
            } catch {
                dlog("\(kind): move → \(name) failed: \(error)")
                return .failed
            }
        }
        // A fresh session was born with a placeholder shell window; now that
        // the real content has landed beside it, drop it (the lowest-index
        // window that doesn't hold the moved pane). Only for sessions WE just
        // created — never prune existing.
        if created, let placeholder = placeholderPane(ofSession: name, excluding: movedPane) {
            _ = try? await link.applyAwait(.killPane(pane: placeholder))
        }
        DIAG("[MODE] \(kind) → session '\(name)' landing=\(landedAsJoin ? "join" : "window") follow=\(isLast) created=\(created)")

        await refreshTmuxSessions()
        return .moved
    }

    /// The target session's current window's active pane — where a Parallel
    /// join docks. Read locally off the mirror (every session's structure is
    /// in it).
    private func activePane(ofSession name: String) -> Int? {
        guard let row = link.sessions.first(where: { $0.name == name }) else { return nil }
        let windows = row.structure.windows.sorted { $0.index < $1.index }
        guard let current = windows.first(where: \.active) ?? windows.first else { return nil }
        let details = current.orderedDetails
        return (details.first(where: \.active) ?? details.first)?.id
    }

    /// The pane of a freshly-created session's placeholder window (its
    /// lowest-indexed window not holding the moved pane).
    private func placeholderPane(ofSession name: String, excluding moved: TmuxPaneID?) -> Int? {
        guard let row = link.state?.sessionState(named: name) else { return nil }
        let windows = row.structure.windows.sorted { $0.index < $1.index }
        for window in windows {
            let ids = window.panes
            if ids.count == 1, let only = ids.first, only != moved?.raw {
                return only
            }
        }
        return nil
    }

    /// The target session's shape, read off the mirror (the frozen product
    /// probed the server; the mirror already carries every session): the
    /// same reading `recomputeSessionMode` does locally — structure decides,
    /// and only the degenerate 1×1 falls back to the remembered mode.
    private enum TargetShape { case tiled, list, unsettled }
    private func probeSessionShape(_ name: String) -> TargetShape {
        guard let row = link.sessions.first(where: { $0.name == name }) else { return .unsettled }
        let counts = row.structure.windows.map { $0.panes.count }.filter { $0 > 0 }
        guard !counts.isEmpty else { return .unsettled }
        if counts.count == 1 {
            if (counts.first ?? 0) > 1 { return .tiled }
            // Degenerate 1×1: only an explicit remembered choice decides
            // (this device's memory — see loadModePreferenceIfNeeded's flag).
            switch UserDefaults.standard.string(forKey: Self.modeOption + "." + name) {
            case TmuxSessionMode.tiled.rawValue: return .tiled
            case TmuxSessionMode.list.rawValue: return .list
            default: return .unsettled
            }
        }
        return counts.contains { $0 > 1 } ? .unsettled : .list
    }

    // MARK: - Window layouts

    /// Apply one of tmux's named layouts to a window. FLAGGED daemon seam:
    /// only the session-wide `applyTiled` verb exists — "tiled" on the
    /// current window of a Parallel session maps onto it exactly; the other
    /// named layouts keep their menu items (same UI) and log until the daemon
    /// grows a select-layout verb.
    @discardableResult
    func applyWindowLayout(_ windowID: TmuxWindowID, layout: String) async -> Bool {
        guard usingTmux, let session = activeTmuxSessionName else { return false }
        guard layout == "tiled", panesByWindow.count == 1 else {
            dlog("applyWindowLayout \(layout): no daemon verb yet (flagged)")
            return false
        }
        do {
            _ = try await link.applyAwait(.applyTiled(session: session))
            return true
        } catch {
            dlog("applyWindowLayout \(layout) failed: \(error)")
            return false
        }
    }
}
