import Foundation
import SwiftTmux

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
///
/// Switching modes IS the structure transformation (break-pane / join-pane —
/// processes untouched, lossless, reversible), shared by every attached
/// device; sizes stay per-device. A degenerate 1×1 session presents as Tiled
/// (Bento's default face) unless the user explicitly chose List, remembered
/// server-side in the `@bento_mode` session option.
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
    /// for the degenerate case). Called after every pane refresh.
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

    /// One-shot read of the session's remembered mode (`@bento_mode`).
    private func loadModePreferenceIfNeeded() {
        guard usingTmux, !modePreferenceLoaded else { return }
        modePreferenceLoaded = true
        Task { [weak self] in
            guard let self else { return }
            if let raw = await self.readSessionOption(Self.modeOption),
               let saved = TmuxSessionMode(rawValue: raw) {
                self.savedModePreference = saved
                self.recomputeSessionMode()
            }
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
        _ = await tmuxService.send(.setSessionOption(name: Self.modeOption, value: mode.rawValue))
        recomputeSessionMode()
        return true
    }

    // MARK: - Grouping & naming

    /// Session panes grouped by window, in `list-panes -s` order (window
    /// order, then pane-index order within each window).
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

    /// The LIVE display name for a window: a single-pane window is named by
    /// its pane's title (what's actually running — auto-updated, never
    /// user-maintained); a multi-pane window (external structures) falls back
    /// to the tmux window name. There is deliberately no rename anywhere.
    func windowDisplayName(_ windowID: TmuxWindowID) -> String {
        let winPanes = panes(in: windowID)
        let windowName = windows.first { $0.id == windowID }?
            .name.trimmingCharacters(in: .whitespaces)
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
    /// every session pane through the one detection pipeline — the SAME
    /// judgment that colors the Tiled pane chrome, never a separate re-run.
    /// Background windows keep reporting because control mode streams every
    /// pane's output and titles.
    func windowState(_ windowID: TmuxWindowID) -> PaneState {
        var sawWorking = false
        for pane in panes(in: windowID) {
            guard let state = paneStates[pane.id] else { continue }
            if case .awaitingInput = state { return state }
            if state == .working { sawWorking = true }
        }
        return sawWorking ? .working : .idle
    }

    // MARK: - Creation (identical in both modes; only the landing differs)

    /// List mode: open a new window seeded per `seed`.
    func newListWindow(_ seed: WindowSeed) async {
        guard usingTmux else { return }
        let (path, command) = await resolveSeed(seed)
        _ = await tmuxService.send(.newWindow(path: path, command: command))
        await refreshWindows()
        await refreshPanes()
    }

    /// Tiled mode: split the active pane, seeded per `seed` (creation parity
    /// with List — duplicate current / specify path+command).
    func splitPane(horizontal: Bool, seed: WindowSeed) async {
        guard usingTmux else { return }
        let (path, command) = await resolveSeed(seed)
        _ = await tmuxService.send(.splitWindow(
            target: activePaneID, horizontal: horizontal, path: path, command: command))
        await refreshPanes()
    }

    /// Resolve a seed to (path, command). "Duplicate current" reads the
    /// active pane's live cwd and start command from tmux; a pane whose
    /// program was typed into a shell has no start command — duplicating it
    /// yields a shell at the same place, which is the honest reading.
    ///
    /// The two seeds carry the program differently: a typed command is a shell
    /// line (`.shell`), while `#{pane_start_command}` comes back already in
    /// tmux's own quoting (`.tmuxSyntax`) and must NOT be re-escaped — doing so
    /// nests the quotes and the new window's process exits at once. See
    /// `SpawnCommand`.
    private func resolveSeed(_ seed: WindowSeed) async -> (String?, SpawnCommand?) {
        switch seed {
        case .custom(let path, let command):
            return (blankToNil(path), blankToNil(command).map(SpawnCommand.shell))
        case .duplicateCurrent:
            guard let pane = activePaneID else { return (nil, nil) }
            // Two queries — a combined format would need a separator, and
            // tmux's command parser eats tabs in unquoted arguments.
            let path = await displayValue("#{pane_current_path}", pane: pane)
            let command = await displayValue("#{pane_start_command}", pane: pane)
            return (path, command.map(SpawnCommand.tmuxSyntax))
        }
    }

    private func displayValue(_ format: String, pane: TmuxPaneID) async -> String? {
        let resp = await tmuxService.send(.displayMessage(format: format, target: pane))
        guard !resp.isError else { return nil }
        return blankToNil(resp.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func blankToNil(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // MARK: - Structure transforms (internals of setMode)

    /// Server-side memory: the pre-spread layout + pane order (for exact
    /// merge-back) and the user's explicit mode choice.
    private static let savedLayoutOption = "@bento_orig_layout"
    private static let savedOrderOption = "@bento_pane_order"
    private static let modeOption = "@bento_mode"

    /// tiled → list: break every pane out into its own window (processes
    /// untouched). For the pure single-window case the layout + pane order
    /// are saved first so merging back restores the exact arrangement; a
    /// mixed structure flattens every multi-pane window with no exact-restore
    /// promise (the UI warned).
    @discardableResult
    internal func spreadToList() async -> Bool {
        guard usingTmux else { return false }
        await refreshWindows()
        await refreshPanes()
        let byWindow = panesByWindow
        let multiPane = byWindow.filter { $0.value.count > 1 }
        guard !multiPane.isEmpty else { return false }

        // Exact-restore memory only for the pure tiled shape.
        if byWindow.count == 1, let winID = multiPane.keys.first,
           let layout = windows.first(where: { $0.id == winID })?.layout, !layout.isEmpty {
            let order = byWindow[winID]!.map { "\($0.id)" }.joined(separator: " ")
            _ = await tmuxService.send(.setSessionOption(name: Self.savedLayoutOption, value: layout))
            _ = await tmuxService.send(.setSessionOption(name: Self.savedOrderOption, value: order))
        }

        for (_, winPanes) in multiPane {
            // Break all but the first; each new window is named for what it
            // runs (compat only — display names derive live from pane titles).
            for pane in winPanes.dropFirst() {
                let name = [pane.title, pane.currentCommand]
                    .compactMap { $0 }.first { !$0.isEmpty } ?? "pane"
                let resp = await tmuxService.send(.breakPane(source: pane.id, name: name))
                if resp.isError { dlog("spreadToList: break-pane \(pane.id) failed: \(resp.output)") }
            }
        }

        await refreshWindows()
        await refreshPanes()
        return true
    }

    /// list → tiled: gather every pane into one window and restore the saved
    /// layout — EDITED to match reality: panes closed while in List have
    /// their cells collapsed into a sibling; windows opened in List split the
    /// largest cell along its longer edge. Survivors return to exactly their
    /// old spots. Join order must match the edited tree's leaf order, because
    /// `select-layout` assigns panes to cells by window order, ignoring the
    /// ids in the layout string (verified). No saved layout, or tree math
    /// failing sanity checks → tmux's even `tiled`.
    @discardableResult
    internal func mergeToTiled() async -> Bool {
        guard usingTmux else { return false }
        await refreshWindows()
        await refreshPanes()
        guard panesByWindow.count > 1 else { return false }

        let savedLayout = await readSessionOption(Self.savedLayoutOption)
        let savedOrder = (await readSessionOption(Self.savedOrderOption))?
            .split(separator: " ")
            .compactMap { TmuxPaneID(string: String($0)) } ?? []
        let live = sessionPanes.compactMap { $0.windowID != nil ? $0.id : nil }

        // Edit the remembered layout tree to the live pane set.
        var tree = savedLayout.flatMap { TmuxLayoutTree.parse($0) }
        if var t = tree {
            let liveRaw = Set(live.map(\.raw))
            for gone in savedOrder where !liveRaw.contains(gone.raw) {
                t = TmuxLayoutTree.removing(pane: gone.raw, from: t) ?? t
            }
            for newcomer in live where !savedOrder.contains(newcomer) {
                t = TmuxLayoutTree.inserting(pane: newcomer.raw, into: t)
            }
            // Sanity: the edited tree must hold exactly the live panes.
            tree = Set(TmuxLayoutTree.leafOrder(of: t)) == liveRaw ? t : nil
        }

        // Join in the tree's leaf order (or saved-then-newcomers without one).
        let ordered: [TmuxPaneID]
        if let tree {
            ordered = TmuxLayoutTree.leafOrder(of: tree).compactMap { raw in
                live.first { $0.raw == raw }
            }
        } else {
            var o = savedOrder.filter { live.contains($0) }
            o += live.filter { !o.contains($0) }
            ordered = o
        }
        guard let base = ordered.first else { return false }

        var prev = base
        for pane in ordered.dropFirst() {
            let resp = await tmuxService.send(.joinPane(source: pane, target: prev))
            // "can't join a pane to its own window" is expected for panes
            // already sharing prev's window (mixed merges) — harmless.
            if resp.isError { dlog("mergeToTiled: join-pane \(pane): \(resp.output)") }
            prev = pane
        }

        await refreshPanes()
        if let baseWin = sessionPanes.first(where: { $0.id == base })?.windowID {
            let layout = tree.map(TmuxLayoutTree.serialize) ?? "tiled"
            _ = await tmuxService.send(.selectLayout(window: baseWin, layout: layout))
        }
        _ = await tmuxService.send(.setSessionOption(name: Self.savedLayoutOption, value: ""))
        _ = await tmuxService.send(.setSessionOption(name: Self.savedOrderOption, value: ""))

        await refreshWindows()
        await refreshPanes()
        return true
    }

    /// Read a session option's value; nil when unset/empty. `show-options -qv`
    /// prints the bare value (quoted only if it contains spaces — strip that).
    private func readSessionOption(_ name: String) async -> String? {
        let resp = await tmuxService.send(.showSessionOption(name: name))
        guard !resp.isError else { return nil }
        var value = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
