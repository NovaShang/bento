import Foundation

/// The gate every tmux client-size declaration passes through on its way to
/// the daemon's session-size authority.
///
/// Why it exists (data-layer divergence from the frozen shell): frozen ran one
/// tmux `-CC` client PER Bento window, so a declaration was that client's own
/// viewport and tmux resolved the rest. On the trunk one daemon-side control
/// client carries the whole session, so every declaration immediately resizes
/// the tmux client — and therefore reflows every pane, redrawing any
/// fullscreen TUI. Declarations must be scarce and monotone: exactly one per
/// real change in the window's own geometry.
///
/// Two rules, both learned from the resize storm in the daemon log:
///
///  * **Dedup.** The same grid never goes out twice. The mirror re-publishes on
///    every structural hop, and each hop re-runs layout; without this a
///    Focus↔Parallel transition (break-pane / join-pane, one pane at a time)
///    declares once per intermediate structure.
///  * **Settle.** While a structure transition is in flight the session is
///    mid-shape: tmux is refusing or reshaping panes (`join-pane … no space
///    for a new pane` in the log came from a size landing mid-merge). Sizes
///    declared then are stashed, and the LAST one is emitted once the
///    transition's barrier ack lands — the structure's own settle point.
struct ViewportDeclarationGate {
    /// The grid currently standing with the daemon (nil = nothing declared yet).
    private(set) var standing: (cols: Int, rows: Int)?
    /// Nesting depth of in-flight structure transitions (spread / merge).
    private(set) var transitionDepth = 0
    /// The declaration held back while a transition is in flight.
    private var deferred: (cols: Int, rows: Int)?

    /// Offer a grid. Returns what should go on the wire, or nil to send nothing.
    /// `force` is the user-initiated override ("Fit session to this window"),
    /// which must re-assert even an unchanged grid — another device may have
    /// shrunk the session since.
    mutating func offer(cols: Int, rows: Int, force: Bool = false) -> (cols: Int, rows: Int)? {
        guard cols > 0, rows > 0 else { return nil }
        if transitionDepth > 0, !force {
            deferred = (cols, rows)
            return nil
        }
        if !force, let standing, standing == (cols, rows) { return nil }
        standing = (cols, rows)
        deferred = nil
        return (cols, rows)
    }

    /// A structure transition started (spread / merge / a verb chain whose
    /// intermediate shapes are not the user's intent).
    mutating func beginTransition() {
        transitionDepth += 1
    }

    /// A structure transition settled. Returns the declaration to emit now —
    /// the last one offered while it ran, if it still differs from what stands.
    mutating func endTransition() -> (cols: Int, rows: Int)? {
        transitionDepth = max(transitionDepth - 1, 0)
        guard transitionDepth == 0, let pending = deferred else { return nil }
        deferred = nil
        return offer(cols: pending.cols, rows: pending.rows)
    }

    /// Forget what stands (the connection dropped, so the daemon no longer
    /// holds this stream's viewport — the next offer must go out).
    mutating func invalidate() {
        standing = nil
    }
}
