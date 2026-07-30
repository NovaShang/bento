import BentoWorkbench
import Foundation
import SwiftTmux
import os

// Seam two, client-side. `DaemonAuthority`'s premise was never "the daemon
// owns structure" — it was "the TMUX SERVER owns structure, and we read it
// through the daemon's mirror". Take the daemon out and the premise is
// unchanged: verbs still become tmux commands, the tree is still a READING of
// tmux's own listings, and nothing is ever mutated optimistically.
//
// The translation table below is the Go one (acphost/tmuxstructure.go),
// command for command — it is the version that was debugged against a real
// server, and divergence between the two would be a bug with no owner.

/// `StructureAuthority` backed by a control-mode connection this process owns.
@MainActor
public final class TmuxAuthority: StructureAuthority {
    private static let log = Logger(subsystem: "com.bento.tmuxpane", category: "authority")

    private let link: TmuxSessionLink

    /// Store slot the projection lands in (`WorkspaceEntry.id`).
    public var entryID: Int

    /// Fan-out of a freshly projected tree — the consumer replaces its entry
    /// wholesale, because the projection IS the whole truth.
    package var onProjection: ((AgentWorkspaceStore.WorkspaceEntry, TmuxStructureState) -> Void)?

    /// Every accepted state, including ones with no projectable entry (an
    /// empty server after the last session died still moves the rev).
    package var onState: ((TmuxStructureState) -> Void)?

    public private(set) var lastState: TmuxStructureState?

    /// Serializes verbs: a verb's effect must be visible to the NEXT verb's
    /// listing, and several of these translate by reading the server first
    /// (reorder, applyTiled, selectPane). Interleaving them would let a
    /// translation read a tree that the previous verb has already changed.
    private var applyChain: Task<Void, Never>?

    public init(link: TmuxSessionLink, entryID: Int = 0) {
        self.link = link
        self.entryID = entryID
        link.onState = { [weak self] state in self?.ingest(state) }
    }

    // MARK: - Write path

    public func apply(_ verb: StructureVerb) {
        let previous = applyChain
        applyChain = Task { [weak self] in
            await previous?.value
            await self?.perform(verb)
        }
    }

    /// Apply and wait until the state that already includes the effect has
    /// been published, answering its rev.
    ///
    /// The daemon's version of this waited on an ack whose rev the SERVER
    /// minted. There is no server minting revs now, so the wait is simply the
    /// verb's own refresh — which is a stronger guarantee, not a weaker one:
    /// `perform` does not return until tmux has been asked again and the
    /// answer has been published.
    @discardableResult
    public func applyAwaiting(_ verb: StructureVerb) async throws -> UInt64 {
        let previous = applyChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.perform(verb)
        }
        applyChain = task
        await task.value
        return lastState?.rev ?? 0
    }

    private func perform(_ verb: StructureVerb) async {
        do {
            let commands = try await translate(verb)
            for command in commands {
                let response = await link.send(command)
                if response.isError {
                    Self.log.error("""
                        tmux refused \(command.commandString, privacy: .public): \
                        \(response.output, privacy: .public)
                        """)
                    break
                }
            }
        } catch {
            Self.log.error("structure verb refused: \(String(describing: error), privacy: .public)")
        }
        // The read path is the answer, always — never an optimistic local
        // mutation. One refresh after the batch publishes what tmux now says.
        await link.refreshStructure()
    }

    enum AuthorityError: LocalizedError {
        case noSuchPane(Int)
        case badArgument(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .noSuchPane(let id): return "No pane %\(id) on this tmux server."
            case .badArgument(let why): return why
            case .unsupported(let why): return why
            }
        }
    }

    // MARK: - Translation (mirrors acphost/tmuxstructure.go)

    private func translate(_ verb: StructureVerb) async throws -> [TmuxCommand] {
        switch verb {
        case .createSession(let name, let cwd):
            guard !name.isEmpty else {
                throw AuthorityError.badArgument("createSession wants a non-empty name")
            }
            return [.newSessionAt(name: name, cwd: cwd)]

        case .killSession(let name):
            return try await translateKillSession(name)

        case .renameSession(let name, let to):
            guard !to.isEmpty else {
                throw AuthorityError.badArgument("renameSession wants a non-empty new name")
            }
            let from = name.isEmpty ? link.sessionName : name
            return [.renameSessionOf(from: from, to: to)]

        case .splitPane(_, let target, let horizontal, let cwd, let command):
            // Pane ids are server-global; the session field routes nothing.
            return [.splitWindow(target: TmuxPaneID(target), horizontal: horizontal,
                                 path: cwd, command: command.map { .shell($0) })]

        case .newPane(let session, let cwd, let command):
            // A standalone pane is a new window holding one pane — the
            // cross-window model's "new pane". Left unnamed so tmux's
            // automatic-rename keeps working; the trailing ':' is tmux target
            // syntax for "next free index in this session".
            let target = session.isEmpty ? nil : "\(session):"
            return [.newWindow(target: target, name: nil, path: cwd,
                               command: command.map { .shell($0) })]

        case .killPane(let pane):
            return [.killPane(id: TmuxPaneID(pane))]

        case .selectPane(let pane):
            return try await translateSelectPane(pane)

        case .renamePane(let pane, let to):
            // pane_title via select-pane -T. A foreground TUI can overwrite it
            // via OSC and tmux emits no notification for it, so the refresh
            // after this batch is what lands it in the tree.
            return [.setPaneTitle(id: TmuxPaneID(pane), title: to)]

        case .toggleZoom(let pane):
            return [.zoomPane(id: TmuxPaneID(pane))]

        case .swapPane(let pane, let up):
            return [up ? .swapPaneUp(id: TmuxPaneID(pane)) : .swapPaneDown(id: TmuxPaneID(pane))]

        case .swapPanes(let a, let b):
            return [.swapPanes(source: TmuxPaneID(a), destination: TmuxPaneID(b))]

        case .dockPane(let source, let at, let horizontal, let before):
            // move-pane, not join-pane: legal within one window too, which is
            // what a drop-zone drag inside a window needs.
            return [.movePane(source: TmuxPaneID(source), target: TmuxPaneID(at),
                              horizontal: horizontal, before: before)]

        case .movePane(let pane, let toSession):
            guard !toSession.isEmpty else {
                throw AuthorityError.badArgument("movePane wants a non-empty destination")
            }
            // The pane moves into its own window in the target session, keeping
            // its server-global id. A source session emptied by the move dies —
            // tmux's own semantics, relayed rather than second-guessed.
            return [.breakPane(source: TmuxPaneID(pane), name: nil, targetSession: toSession)]

        case .resizePane(let pane, let direction, let amount):
            let dir = direction.uppercased()
            guard ["L", "R", "U", "D"].contains(dir) else {
                throw AuthorityError.badArgument(
                    "resizePane direction must be L/R/U/D, got \(direction)")
            }
            guard amount > 0 else {
                throw AuthorityError.badArgument(
                    "resizePane amount must be positive, got \(amount)")
            }
            return [.resizePaneBy(id: TmuxPaneID(pane), direction: dir, amount: amount)]

        case .reorderPanes(let session, let order):
            return try await translateReorderPanes(session: session, order: order)

        case .applyTiled(let session):
            return try await translateApplyTiled(session: session)
        }
    }

    /// Focusing a pane in another window means selecting that window too: the
    /// client's "selectPane" is "put my focus here", not tmux's narrower
    /// per-window notion. Looked up server-wide — the pane may be anywhere.
    private func translateSelectPane(_ pane: Int) async throws -> [TmuxCommand] {
        let id = TmuxPaneID(pane)
        let panes = try await listAllPanes()
        guard let found = panes.first(where: { $0.id == id }) else {
            throw AuthorityError.noSuchPane(pane)
        }
        var commands: [TmuxCommand] = []
        if let window = found.windowID, !found.inActiveWindow {
            commands.append(.selectWindow(id: window))
        }
        commands.append(.selectPane(id: id))
        return commands
    }

    /// Killing the CURRENT session with survivors switches away first, so the
    /// control client outlives the kill — tmux's default detach-on-destroy
    /// would otherwise take it down, and every pane subscription with it.
    private func translateKillSession(_ name: String) async throws -> [TmuxCommand] {
        let target = name.isEmpty ? link.sessionName : name
        let response = await link.send(.listSessions)
        guard !response.isError else {
            throw AuthorityError.badArgument("tmux refused list-sessions")
        }
        var exists = false
        var survivor: String?
        for line in response.output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let sessionName = String(parts[1])
            if sessionName == target {
                exists = true
            } else if survivor == nil {
                survivor = String(parts[0])   // rename-stable $id
            }
        }
        guard exists else { return [] }

        var commands: [TmuxCommand] = []
        if target == link.sessionName, let survivor {
            commands.append(.switchClient(session: survivor))
        }
        commands.append(.killSession(name: target))
        return commands
    }

    /// Sort the session's windows so the session-wide pane order becomes
    /// `order`. Only defined when every pane occupies its own window (the
    /// Parallel shape) — then pane order IS window order and a swap chain
    /// realizes it exactly. Any richer shape has no faithful tmux translation
    /// of "reorder this flat list", so it refuses rather than guessing.
    private func translateReorderPanes(session: String, order: [Int]) async throws -> [TmuxCommand] {
        let (windows, panes) = try await listStructure(session: session)
        guard order.count == panes.count else {
            throw AuthorityError.badArgument(
                "reorderPanes names \(order.count) panes, session has \(panes.count)")
        }
        var paneWindow: [TmuxPaneID: TmuxWindowID] = [:]
        var perWindow: [TmuxWindowID: Int] = [:]
        for pane in panes {
            guard let window = pane.windowID else {
                throw AuthorityError.unsupported("pane listing carried no window ids")
            }
            paneWindow[pane.id] = window
            perWindow[window, default: 0] += 1
        }
        if let crowded = perWindow.first(where: { $0.value > 1 }) {
            throw AuthorityError.unsupported("""
                reorderPanes is only defined when every pane has its own window; \
                window \(crowded.key) holds \(crowded.value)
                """)
        }

        var desired: [TmuxWindowID] = []
        var seen: Set<TmuxPaneID> = []
        for raw in order {
            let id = TmuxPaneID(raw)
            guard let window = paneWindow[id] else {
                throw AuthorityError.badArgument(
                    "reorderPanes names pane \(id), which is not in this session")
            }
            guard seen.insert(id).inserted else {
                throw AuthorityError.badArgument("reorderPanes names pane \(id) twice")
            }
            desired.append(window)
        }

        // Selection sort by id: `current` is list-windows order, and
        // swap-window exchanges two windows' positions.
        var current = windows.map(\.id).filter { (perWindow[$0] ?? 0) > 0 }
        var commands: [TmuxCommand] = []
        for i in desired.indices {
            guard current[i] != desired[i] else { continue }
            guard let j = current[(i + 1)...].firstIndex(of: desired[i]) else {
                throw AuthorityError.unsupported("window \(desired[i]) vanished during reorder")
            }
            commands.append(.swapWindows(a: desired[i], b: current[i]))
            current.swapAt(i, j)
        }
        return commands
    }

    /// Gather every pane of the session into the first pane's window — each
    /// join targeting the previous, so session-wide order becomes window
    /// order — then apply the tiled layout. Panes already in the base window
    /// keep their place in the chain but need no join (join-pane refuses a
    /// same-window move).
    private func translateApplyTiled(session: String) async throws -> [TmuxCommand] {
        let (_, panes) = try await listStructure(session: session)
        guard let first = panes.first else {
            throw AuthorityError.badArgument("session has no panes")
        }
        guard let baseWindow = first.windowID else {
            throw AuthorityError.unsupported("pane listing carried no window ids")
        }
        guard panes.count > 1 else {
            // One pane fills its window; tiled is a no-op but still legal.
            return [.selectLayout(window: baseWindow, layout: "tiled")]
        }
        var commands: [TmuxCommand] = []
        var previous = first.id
        for pane in panes.dropFirst() {
            if pane.windowID != baseWindow {
                commands.append(.joinPane(source: pane.id, target: previous))
            }
            previous = pane.id
        }
        commands.append(.selectLayout(window: baseWindow, layout: "tiled"))
        return commands
    }

    // MARK: - Listings

    private func listAllPanes() async throws -> [SwiftTmux.Pane] {
        let response = await link.send(.listPanes(allWindows: true))
        guard !response.isError else {
            throw AuthorityError.badArgument("tmux refused list-panes -a")
        }
        return TmuxParsers.parsePaneList(response.output)
    }

    private func listStructure(session: String) async throws -> ([TmuxWindow], [SwiftTmux.Pane]) {
        let target = session.isEmpty ? link.sessionName : session
        let windowsResponse = await link.send(.listWindows(target: target))
        guard !windowsResponse.isError else {
            throw AuthorityError.badArgument("tmux refused list-windows")
        }
        let panesResponse = await link.send(.listPanes(target: target, sessionWide: true))
        guard !panesResponse.isError else {
            throw AuthorityError.badArgument("tmux refused list-panes -s")
        }
        return (
            TmuxParsers.parseWindowList(windowsResponse.output),
            TmuxParsers.parsePaneList(panesResponse.output)
        )
    }

    // MARK: - Read path

    /// Accept one freshly built state. Stale revs are dropped — the guard is
    /// kept from `DaemonAuthority` even though a local counter cannot go
    /// backwards, because the consumers downstream rely on it being monotonic.
    @discardableResult
    public func ingest(_ state: TmuxStructureState) -> Bool {
        if let last = lastState, state.rev <= last.rev { return false }
        lastState = state
        onState?(state)
        guard let entry = state.workspaceEntry(entryID: entryID) else { return false }
        onProjection?(entry, state)
        return true
    }
}
