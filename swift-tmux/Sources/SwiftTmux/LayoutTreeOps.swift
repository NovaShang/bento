import Foundation

/// The tmux layout verbs, as pure tree edits. The terminal path never calls
/// these — tmux itself does the math server-side. They exist for the ACP
/// backend, where Bento owns the window layout locally and must reproduce
/// tmux's split / kill / resize / swap / dock semantics exactly so the tiled
/// host renders identical geometry.
///
/// Every op returns a fully renormalized tree (sizes + offsets recomputed,
/// one-cell dividers between siblings), matching what tmux would report in
/// `#{window_layout}` after the equivalent command.
public extension TmuxLayoutTree {
    // MARK: - Canvas

    /// A fresh single-pane layout filling the canvas.
    static func single(pane id: Int, w: Int, h: Int) -> Node {
        .leaf(id: id, w: w, h: h, x: 0, y: 0)
    }

    /// Renormalize a tree to a new canvas size (client resize / Fit Session).
    static func resized(_ node: Node, w: Int, h: Int) -> Node {
        renormalized(node, w: w, h: h, x: 0, y: 0)
    }

    // MARK: - Split (tmux split-window -h/-v on a target pane)

    /// Split `target`'s cell in two along the given axis and put `newID` in
    /// the second half (`newFirst` puts it in the first half instead — the
    /// "dock before" case). `horizontal` matches tmux `-h`: side by side.
    /// Same-axis nesting is flattened into the parent container (tmux's
    /// canonical form). nil when `target` is missing or `newID` already used.
    static func splitting(pane target: Int, adding newID: Int, horizontal: Bool,
                          newFirst: Bool = false, in node: Node) -> Node? {
        let ids = leafOrder(of: node)
        guard ids.contains(target), !ids.contains(newID) else { return nil }

        /// The freshly-created two-leaf container (target + new), and nothing
        /// else — the only shape same-axis flattening may dissolve.
        func isFreshSplit(_ n: Node) -> Bool {
            let children: [Node]
            switch (n, horizontal) {
            case (.hsplit(_, _, _, _, let c), true): children = c
            case (.vsplit(_, _, _, _, let c), false): children = c
            default: return false
            }
            guard children.count == 2 else { return false }
            let leafIDs = children.compactMap { child -> Int? in
                if case .leaf(let id, _, _, _, _) = child { return id }
                return nil
            }
            return leafIDs.count == 2 && leafIDs.contains(newID) && leafIDs.contains(target)
        }

        func rebuild(_ n: Node) -> Node {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                guard id == target else { return n }
                if horizontal {
                    let first = (w - 1) / 2, second = w - 1 - first
                    let a = Node.leaf(id: newFirst ? newID : id, w: first, h: h, x: x, y: y)
                    let b = Node.leaf(id: newFirst ? id : newID, w: second, h: h, x: x + first + 1, y: y)
                    return .hsplit(w: w, h: h, x: x, y: y, children: [a, b])
                } else {
                    let first = (h - 1) / 2, second = h - 1 - first
                    let a = Node.leaf(id: newFirst ? newID : id, w: w, h: first, x: x, y: y)
                    let b = Node.leaf(id: newFirst ? id : newID, w: w, h: second, x: x, y: y + first + 1)
                    return .vsplit(w: w, h: h, x: x, y: y, children: [a, b])
                }
            case .hsplit(let w, let h, let x, let y, let children):
                var out: [Node] = []
                for child in children.map(rebuild) {
                    if horizontal, isFreshSplit(child),
                       case .hsplit(_, _, _, _, let grand) = child {
                        out.append(contentsOf: grand)   // flatten same-axis nesting
                    } else {
                        out.append(child)
                    }
                }
                return .hsplit(w: w, h: h, x: x, y: y, children: out)
            case .vsplit(let w, let h, let x, let y, let children):
                var out: [Node] = []
                for child in children.map(rebuild) {
                    if !horizontal, isFreshSplit(child),
                       case .vsplit(_, _, _, _, let grand) = child {
                        out.append(contentsOf: grand)
                    } else {
                        out.append(child)
                    }
                }
                return .vsplit(w: w, h: h, x: x, y: y, children: out)
            }
        }
        return renormalized(rebuild(node), w: node.width, h: node.height, x: 0, y: 0)
    }

    // MARK: - Swap (tmux swap-pane: content follows ids, geometry stays)

    /// Exchange two panes' positions. Geometry is untouched — only the ids
    /// trade places, exactly like tmux swap-pane.
    static func swapping(_ a: Int, _ b: Int, in node: Node) -> Node {
        func rebuild(_ n: Node) -> Node {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                if id == a { return .leaf(id: b, w: w, h: h, x: x, y: y) }
                if id == b { return .leaf(id: a, w: w, h: h, x: x, y: y) }
                return n
            case .hsplit(let w, let h, let x, let y, let children):
                return .hsplit(w: w, h: h, x: x, y: y, children: children.map(rebuild))
            case .vsplit(let w, let h, let x, let y, let children):
                return .vsplit(w: w, h: h, x: x, y: y, children: children.map(rebuild))
            }
        }
        return rebuild(node)
    }

    /// The pane before / after `id` in depth-first leaf order, wrapping —
    /// tmux swap-pane -U / -D targets.
    static func neighbor(of id: Int, previous: Bool, in node: Node) -> Int? {
        let order = leafOrder(of: node)
        guard order.count > 1, let idx = order.firstIndex(of: id) else { return nil }
        let n = order.count
        return order[((idx + (previous ? -1 : 1)) % n + n) % n]
    }

    // MARK: - Resize (tmux resize-pane -L/-R/-U/-D)

    /// Move `id`'s border in `direction` ("L"/"R"/"U"/"D") by `amount` cells:
    /// R = right border right (grow), L = right border left (shrink), and the
    /// vertical pair likewise — falling back to the opposite border when the
    /// pane has no sibling on that side, mirroring tmux. Unchanged tree when
    /// nothing can move.
    static func resizing(pane id: Int, direction: String, amount: Int, in node: Node) -> Node {
        guard amount > 0 else { return node }
        let horizontal = (direction == "L" || direction == "R")
        let grow = (direction == "R" || direction == "D")
        guard let adjusted = adjustBoundary(pane: id, horizontal: horizontal,
                                            delta: grow ? amount : -amount, in: node) else {
            return node
        }
        return renormalized(adjusted, w: node.width, h: node.height, x: 0, y: 0)
    }

    /// Grow/shrink the subtree containing `pane` along an axis by `delta`,
    /// compensating the next sibling (or the previous one when the subtree is
    /// the container's last child). nil = no ancestor on that axis.
    private static func adjustBoundary(pane id: Int, horizontal: Bool,
                                       delta: Int, in node: Node) -> Node? {
        func extent(_ n: Node) -> Int { horizontal ? n.width : n.height }

        /// Overwrite a node's own extent (children untouched — a following
        /// renormalize redistributes them).
        func withExtent(_ n: Node, _ e: Int) -> Node {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                return .leaf(id: id, w: horizontal ? e : w, h: horizontal ? h : e, x: x, y: y)
            case .hsplit(let w, let h, let x, let y, let c):
                return .hsplit(w: horizontal ? e : w, h: horizontal ? h : e, x: x, y: y, children: c)
            case .vsplit(let w, let h, let x, let y, let c):
                return .vsplit(w: horizontal ? e : w, h: horizontal ? h : e, x: x, y: y, children: c)
            }
        }

        func rebuild(_ n: Node) -> (node: Node, handled: Bool) {
            switch n {
            case .leaf:
                return (n, false)
            case .hsplit(let w, let h, let x, let y, let children):
                if horizontal, let idx = children.firstIndex(where: { leafOrder(of: $0).contains(id) }) {
                    // Deeper ancestor first: only adjust here if no matching
                    // container below already handled it.
                    let (rebuilt, handled) = rebuild(children[idx])
                    if handled {
                        var c = children; c[idx] = rebuilt
                        return (.hsplit(w: w, h: h, x: x, y: y, children: c), true)
                    }
                    var c = children
                    let partner = idx + 1 < c.count ? idx + 1 : idx - 1
                    guard partner >= 0, partner != idx else { break }
                    let mine = extent(c[idx]), theirs = extent(c[partner])
                    let d = max(min(delta, theirs - 1), 1 - mine)   // both stay ≥1
                    guard d != 0 else { return (n, true) }
                    c[idx] = withExtent(c[idx], mine + d)
                    c[partner] = withExtent(c[partner], theirs - d)
                    return (.hsplit(w: w, h: h, x: x, y: y, children: c), true)
                }
                var c = [Node](); var handled = false
                for child in children {
                    let r = rebuild(child)
                    c.append(r.node); handled = handled || r.handled
                }
                return (.hsplit(w: w, h: h, x: x, y: y, children: c), handled)
            case .vsplit(let w, let h, let x, let y, let children):
                if !horizontal, let idx = children.firstIndex(where: { leafOrder(of: $0).contains(id) }) {
                    let (rebuilt, handled) = rebuild(children[idx])
                    if handled {
                        var c = children; c[idx] = rebuilt
                        return (.vsplit(w: w, h: h, x: x, y: y, children: c), true)
                    }
                    var c = children
                    let partner = idx + 1 < c.count ? idx + 1 : idx - 1
                    guard partner >= 0, partner != idx else { break }
                    let mine = extent(c[idx]), theirs = extent(c[partner])
                    let d = max(min(delta, theirs - 1), 1 - mine)
                    guard d != 0 else { return (n, true) }
                    c[idx] = withExtent(c[idx], mine + d)
                    c[partner] = withExtent(c[partner], theirs - d)
                    return (.vsplit(w: w, h: h, x: x, y: y, children: c), true)
                }
                var c = [Node](); var handled = false
                for child in children {
                    let r = rebuild(child)
                    c.append(r.node); handled = handled || r.handled
                }
                return (.vsplit(w: w, h: h, x: x, y: y, children: c), handled)
            }
            return (n, false)
        }

        let (result, handled) = rebuild(node)
        return handled ? result : nil
    }

    // MARK: - Dock (tmux move-pane: re-split target, move source into the half)

    /// Remove `source` from the tree and re-insert it by splitting `target`
    /// along `horizontal`, landing `before` or after — the VS Code edge-dock
    /// drop. nil when the move is impossible (same pane, missing ids, or
    /// source is the only pane).
    static func docking(pane source: Int, at target: Int, horizontal: Bool,
                        before: Bool, in node: Node) -> Node? {
        guard source != target else { return nil }
        guard let without = removing(pane: source, from: node) else { return nil }
        guard leafOrder(of: without).contains(target) else { return nil }
        return splitting(pane: target, adding: source, horizontal: horizontal,
                         newFirst: before, in: without)
    }
}
