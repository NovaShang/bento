import BentoFoundation
import BentoUI
import Foundation

// Seam two: WHO gets to write workspace structure. The two products state
// opposite truths — here the client store is authoritative (mutate locally,
// then push statekv); in the tmux product the server is ("a READING of the
// tmux session's structure, never client-side state"). The read path is
// identical either way (state + statechanged); only the WRITE path differs.
// This file names the write path so a server-authoritative implementation
// (P7's DaemonAuthority translating verbs to `structure/apply`) can slot in
// without re-teaching every caller.

/// One workspace-structure mutation, in the vocabulary both products'
/// stores were measured to share (split/close/select/zoom/swap/dock/move/
/// resize/reorder + session create/kill/rename).
public enum StructureVerb: Sendable {
    case createSession(name: String, cwd: String?)
    case killSession(name: String)
    case renameSession(name: String, to: String)

    case splitPane(session: String, target: Int, horizontal: Bool,
                   cwd: String?, command: String?)
    case newPane(session: String, cwd: String?, command: String?)
    case killPane(pane: Int)
    case selectPane(pane: Int)
    case renamePane(pane: Int, to: String)
    case toggleZoom(pane: Int)
    case swapPane(pane: Int, up: Bool)
    case swapPanes(a: Int, b: Int)
    case dockPane(source: Int, at: Int, horizontal: Bool, before: Bool)
    case movePane(pane: Int, toSession: String)
    case resizePane(pane: Int, direction: String, amount: Int)
    case reorderPanes(session: String, order: [Int])
    case applyTiled(session: String)
}

/// The executor of structure verbs. Callers hand a verb over and then
/// observe the resulting tree through the normal read path — they never
/// assume the mutation happened synchronously (a server authority won't).
///
/// P7 note: verbs whose local implementations return ids (`newPane`,
/// `splitPane`) surface those through the read path's structure events;
/// whether DaemonAuthority needs an explicit result channel is decided
/// when `internal/host/tmux` exists, not guessed here.
@MainActor
public protocol StructureAuthority: AnyObject {
    func apply(_ verb: StructureVerb)
}

/// The client-authoritative implementation: today's store behavior,
/// verbatim — mutate the local tree, persist, mirror via statekv.
extension AgentWorkspaceStore: StructureAuthority {
    public func apply(_ verb: StructureVerb) {
        switch verb {
        case .createSession(let name, let cwd):
            createSession(name, cwd: cwd)
        case .killSession(let name):
            killSession(name)
        case .renameSession(let name, let newName):
            renameSession(name, to: newName)
        case .splitPane(let session, let target, let horizontal, let cwd, let command):
            _ = splitPane(session: session, target: target, horizontal: horizontal,
                          cwd: cwd, command: command)
        case .newPane(let session, let cwd, let command):
            _ = newPane(session: session, cwd: cwd, command: command)
        case .killPane(let pane):
            killPane(pane)
        case .selectPane(let pane):
            selectPane(pane)
        case .renamePane(let pane, let title):
            renamePane(pane, to: title)
        case .toggleZoom(let pane):
            toggleZoom(pane)
        case .swapPane(let pane, let up):
            swapPane(pane, up: up)
        case .swapPanes(let a, let b):
            swapPanes(a, b)
        case .dockPane(let source, let target, let horizontal, let before):
            dockPane(source, at: target, horizontal: horizontal, before: before)
        case .movePane(let pane, let dest):
            _ = movePane(pane, toSession: dest)
        case .resizePane(let pane, let direction, let amount):
            resizePane(pane, direction: direction, amount: amount)
        case .reorderPanes(let session, let order):
            reorderPanes(session: session, order: order)
        case .applyTiled(let session):
            applyTiled(session: session)
        }
    }
}
