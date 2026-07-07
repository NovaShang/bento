import Foundation
import SwiftTmux

/// The hierarchical structure model: Bento's two view modes are READINGS of
/// the tmux session's structure, never client-side state.
///
///   list  = the window layer (each window is one list item)
///   tiled = the pane layer inside one window
///
/// A session with one single-pane window is degenerate (both modes coincide);
/// one window with N panes is tiled; N windows are a list — whose items open
/// into a tiled view when they hold more than one pane (hierarchical mixed
/// state). Any tmux session — including ones made by hand over plain SSH —
/// maps onto a state with no adaptation, and switching modes IS a structure
/// transformation (`spreadToList` / `mergeToTiled`), shared by every attached
/// device. Sizes stay per-device (tracking/pinned); structure is global.
public enum TmuxSessionStructure: Equatable, Sendable {
    /// One window, one pane — list and tiled coincide.
    case degenerate
    /// One window, many panes.
    case tiled
    /// Many windows, every one a single pane.
    case list
    /// Many windows, at least one holding multiple panes. The list view shows
    /// windows; multi-pane items open into that window's tiled view.
    case hierarchical
}

@MainActor
public extension TerminalViewModel {
    // MARK: - Derived structure

    /// The session's current structure, derived purely from `sessionPanes`.
    var sessionStructure: TmuxSessionStructure {
        let byWindow = panesByWindow
        if byWindow.count <= 1 {
            return (sessionPanes.count > 1) ? .tiled : .degenerate
        }
        return byWindow.values.contains { $0.count > 1 } ? .hierarchical : .list
    }

    /// Session panes grouped by window, in `list-panes -s` order (window
    /// order, then pane-index order within each window — the order the
    /// spread/merge recipe depends on).
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

    /// Aggregate agent state for a window's list item, highest priority first:
    /// any pane awaiting input → awaiting; else any working → working; else
    /// idle. Background windows keep reporting because control mode streams
    /// every pane's output (verified) — StateDetection sees all of it.
    func windowState(_ windowID: TmuxWindowID) -> PaneState {
        var sawWorking = false
        for pane in panes(in: windowID) {
            let state = stateDetection.detectState(
                pane: pane.id, currentCommand: pane.currentCommand, title: pane.title)
            if case .awaitingInput = state { return state }
            if state == .working { sawWorking = true }
        }
        return sawWorking ? .working : .idle
    }

    // MARK: - Structure ops (the mode switch)

    /// tmux user options that persist the pre-spread layout server-side, so a
    /// later merge restores the exact tiling — from any device, after any app
    /// restart. One saved layout per session (the last spread wins).
    private static let savedLayoutOption = "@bento_orig_layout"
    private static let savedOrderOption = "@bento_pane_order"

    /// tiled → list: break every pane of the current window out into its own
    /// window (processes untouched), saving the layout + pane order first so
    /// `mergeToTiled` can restore the exact arrangement. Returns false when
    /// there's nothing to spread.
    @discardableResult
    func spreadToList() async -> Bool {
        guard usingTmux else { return false }
        await refreshWindows()
        await refreshPanes()
        guard let winID = activeWindowID ?? windows.first(where: \.isActive)?.id else { return false }
        let winPanes = panes(in: winID)
        guard winPanes.count > 1 else { return false }
        guard let layout = windows.first(where: { $0.id == winID })?.layout, !layout.isEmpty
        else { return false }

        let order = winPanes.map { "\($0.id)" }.joined(separator: " ")
        _ = await tmuxService.send(.setSessionOption(name: Self.savedLayoutOption, value: layout))
        _ = await tmuxService.send(.setSessionOption(name: Self.savedOrderOption, value: order))

        // Break all but the first pane; the original window keeps its name and
        // the remaining pane. Each new window is named for what it runs.
        for pane in winPanes.dropFirst() {
            let name = [pane.title, pane.currentCommand]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "pane"
            let resp = await tmuxService.send(.breakPane(source: pane.id, name: name))
            if resp.isError { dlog("spreadToList: break-pane \(pane.id) failed: \(resp.output)") }
        }

        await refreshWindows()
        await refreshPanes()
        return true
    }

    /// list → tiled: gather every pane in the session into one window and
    /// restore the saved layout. Join order rebuilds the ORIGINAL pane order
    /// (chained `-t previous`) — `select-layout` maps geometry slots by the
    /// window's current pane order and ignores the pane ids embedded in the
    /// layout string, so order is what puts each process back in its own cell
    /// (verified round-trip). Panes that appeared since the spread are
    /// appended; if the live pane set no longer matches the saved one, fall
    /// back to tmux's even `tiled` layout instead of a stale exact layout.
    @discardableResult
    func mergeToTiled() async -> Bool {
        guard usingTmux else { return false }
        await refreshWindows()
        await refreshPanes()
        guard panesByWindow.count > 1 else { return false }

        let savedLayout = await readSessionOption(Self.savedLayoutOption)
        let savedOrder = (await readSessionOption(Self.savedOrderOption))?
            .split(separator: " ")
            .compactMap { TmuxPaneID(string: String($0)) } ?? []

        let live = sessionPanes.compactMap { $0.windowID != nil ? $0.id : nil }
        var ordered = savedOrder.filter { live.contains($0) }
        ordered += live.filter { !ordered.contains($0) }
        guard let base = ordered.first else { return false }

        var prev = base
        for pane in ordered.dropFirst() {
            let resp = await tmuxService.send(.joinPane(source: pane, target: prev))
            // "can't join a pane to its own window" is expected for panes
            // already sharing prev's window (hierarchical merges) — harmless.
            if resp.isError { dlog("mergeToTiled: join-pane \(pane): \(resp.output)") }
            prev = pane
        }

        // Re-resolve the merged window, then lay it out: exact restore only
        // when the live pane set is exactly the saved one.
        await refreshPanes()
        if let baseWin = sessionPanes.first(where: { $0.id == base })?.windowID {
            let exact = savedLayout.flatMap { layout in
                (!layout.isEmpty && Set(savedOrder) == Set(live)) ? layout : nil
            }
            _ = await tmuxService.send(.selectLayout(window: baseWin, layout: exact ?? "tiled"))
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
