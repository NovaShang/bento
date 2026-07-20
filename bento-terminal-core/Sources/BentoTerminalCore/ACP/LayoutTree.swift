import Foundation

/// Bento's split-pane layout model: a tree of cells on an integer-cell
/// canvas, one-cell dividers between siblings. This is the workspace's own
/// geometry (no external multiplexer involved) — the store persists the tree
/// directly (Codable) and every structure verb below returns a fully
/// renormalized tree (sizes + offsets recomputed).
///
/// Cell semantics survive from the terminal era on purpose: the tiled host
/// renders cell-exact tiling (title bar = one cell), so irregular splits
/// stay aligned.
public enum LayoutTree {
    public indirect enum Node: Equatable, Sendable {
        case leaf(id: Int, w: Int, h: Int, x: Int, y: Int)
        case hsplit(w: Int, h: Int, x: Int, y: Int, children: [Node])
        case vsplit(w: Int, h: Int, x: Int, y: Int, children: [Node])

        var width: Int {
            switch self {
            case .leaf(_, let w, _, _, _), .hsplit(let w, _, _, _, _), .vsplit(let w, _, _, _, _): return w
            }
        }
        var height: Int {
            switch self {
            case .leaf(_, _, let h, _, _), .hsplit(_, let h, _, _, _), .vsplit(_, let h, _, _, _): return h
            }
        }
    }

    // MARK: - Canvas

    /// A fresh single-pane layout filling the canvas.
    public static func single(pane id: Int, w: Int, h: Int) -> Node {
        .leaf(id: id, w: w, h: h, x: 0, y: 0)
    }

    /// Renormalize a tree to a new canvas size (client resize / Fit Session).
    public static func resized(_ node: Node, w: Int, h: Int) -> Node {
        renormalized(node, w: w, h: h, x: 0, y: 0)
    }

    // MARK: - Reading

    /// The pane ids of the leaves in depth-first order — the stable "pane
    /// order" every ordinal (⌘1-9, sidebar rows) addresses.
    public static func leafOrder(of node: Node) -> [Int] {
        switch node {
        case .leaf(let id, _, _, _, _): return [id]
        case .hsplit(_, _, _, _, let children), .vsplit(_, _, _, _, let children):
            return children.flatMap(leafOrder)
        }
    }

    /// Every leaf's frame, keyed by pane id.
    public static func frames(of node: Node) -> [Int: (w: Int, h: Int, x: Int, y: Int)] {
        var out: [Int: (w: Int, h: Int, x: Int, y: Int)] = [:]
        func walk(_ n: Node) {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                out[id] = (w, h, x, y)
            case .hsplit(_, _, _, _, let children), .vsplit(_, _, _, _, let children):
                children.forEach(walk)
            }
        }
        walk(node)
        return out
    }

    // MARK: - Split (split a target pane's cell along an axis)

    /// Split `target`'s cell in two along the given axis and put `newID` in
    /// the second half (`newFirst` puts it in the first half instead — the
    /// "dock before" case). `horizontal` = side by side. Same-axis nesting is
    /// flattened into the parent container (canonical form). nil when
    /// `target` is missing or `newID` already used.
    public static func splitting(pane target: Int, adding newID: Int, horizontal: Bool,
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

    // MARK: - Remove

    /// Remove a pane's leaf; its cell collapses into a sibling (the container
    /// renormalizes, so the space is shared proportionally — visually the
    /// neighbors absorb it). Returns nil when the pane isn't present or it
    /// was the only leaf.
    public static func removing(pane id: Int, from node: Node) -> Node? {
        guard let pruned = prune(id, node) else { return nil }
        return renormalized(pruned, w: node.width, h: node.height, x: 0, y: 0)
    }

    private static func prune(_ id: Int, _ node: Node) -> Node? {
        switch node {
        case .leaf(let lid, _, _, _, _):
            return lid == id ? nil : node
        case .hsplit(let w, let h, let x, let y, let children):
            // No "unchanged" shortcut on child COUNT — a grandchild edit
            // doesn't change it. Always rebuild from the pruned children.
            let kept = children.compactMap { prune(id, $0) }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }             // container dissolves
            return .hsplit(w: w, h: h, x: x, y: y, children: kept)
        case .vsplit(let w, let h, let x, let y, let children):
            let kept = children.compactMap { prune(id, $0) }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }
            return .vsplit(w: w, h: h, x: x, y: y, children: kept)
        }
    }

    // MARK: - Insert (new pane, no explicit target)

    /// Insert a new pane by splitting the largest leaf along its longer edge
    /// — where a person would put it to keep the arrangement balanced, and
    /// nobody else moves.
    public static func inserting(pane id: Int, into node: Node) -> Node {
        guard let target = largestLeaf(node),
              let split = splitting(pane: target, adding: id,
                                    horizontal: preferHorizontal(target, in: node),
                                    in: node) else { return node }
        return split
    }

    private static func largestLeaf(_ node: Node) -> Int? {
        var best: (id: Int, area: Int)?
        func walk(_ n: Node) {
            switch n {
            case .leaf(let id, let w, let h, _, _):
                let area = w * h
                if best == nil || area > best!.area { best = (id, area) }
            case .hsplit(_, _, _, _, let c), .vsplit(_, _, _, _, let c):
                c.forEach(walk)
            }
        }
        walk(node)
        return best?.id
    }

    private static func preferHorizontal(_ id: Int, in node: Node) -> Bool {
        guard let frame = frames(of: node)[id] else { return true }
        return frame.w >= frame.h
    }

    // MARK: - Swap (content follows ids, geometry stays)

    /// Exchange two panes' positions. Geometry is untouched — only the ids
    /// trade places.
    public static func swapping(_ a: Int, _ b: Int, in node: Node) -> Node {
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

    /// The pane before / after `id` in depth-first leaf order, wrapping.
    public static func neighbor(of id: Int, previous: Bool, in node: Node) -> Int? {
        let order = leafOrder(of: node)
        guard order.count > 1, let idx = order.firstIndex(of: id) else { return nil }
        let n = order.count
        return order[((idx + (previous ? -1 : 1)) % n + n) % n]
    }

    // MARK: - Resize (move a pane's border)

    /// Move `id`'s border in `direction` ("L"/"R"/"U"/"D") by `amount` cells:
    /// R = right border right (grow), L = right border left (shrink), and the
    /// vertical pair likewise — falling back to the opposite border when the
    /// pane has no sibling on that side. Unchanged tree when nothing can move.
    public static func resizing(pane id: Int, direction: String, amount: Int, in node: Node) -> Node {
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

    // MARK: - Dock (re-split target, move source into the half)

    /// Remove `source` from the tree and re-insert it by splitting `target`
    /// along `horizontal`, landing `before` or after — the VS Code edge-dock
    /// drop. nil when the move is impossible (same pane, missing ids, or
    /// source is the only pane).
    public static func docking(pane source: Int, at target: Int, horizontal: Bool,
                               before: Bool, in node: Node) -> Node? {
        guard source != target else { return nil }
        guard let without = removing(pane: source, from: node) else { return nil }
        guard leafOrder(of: without).contains(target) else { return nil }
        return splitting(pane: target, adding: source, horizontal: horizontal,
                         newFirst: before, in: without)
    }

    // MARK: - Tiled preset

    /// As square a grid as fits, rows filled top-down — the "even out
    /// everything" arrangement.
    public static func tiledPreset(panes: [Int], cols: Int, rows: Int) -> Node? {
        guard let first = panes.first else { return nil }
        guard panes.count > 1 else {
            return .leaf(id: first, w: cols, h: rows, x: 0, y: 0)
        }
        let columns = Int(Double(panes.count).squareRoot().rounded(.up))
        let rowCount = Int((Double(panes.count) / Double(columns)).rounded(.up))
        var rowsNodes: [Node] = []
        var index = 0
        for _ in 0..<rowCount {
            let slice = panes[index..<min(index + columns, panes.count)]
            index += slice.count
            let leaves = slice.map { Node.leaf(id: $0, w: 1, h: 1, x: 0, y: 0) }
            if leaves.count == 1 {
                rowsNodes.append(leaves[0])
            } else {
                rowsNodes.append(.hsplit(w: cols, h: 1, x: 0, y: 0, children: leaves))
            }
        }
        let root: Node
        if rowsNodes.count == 1 {
            root = rowsNodes[0]
        } else {
            root = .vsplit(w: cols, h: rows, x: 0, y: 0, children: rowsNodes)
        }
        return resized(root, w: cols, h: rows)
    }

    // MARK: - Renormalize

    /// Recompute every node's size and offset: distribute each container's
    /// extent to its children proportionally to their previous sizes (with
    /// one divider cell between siblings), recursively.
    static func renormalized(_ node: Node, w: Int, h: Int, x: Int, y: Int) -> Node {
        switch node {
        case .leaf(let id, _, _, _, _):
            return .leaf(id: id, w: w, h: h, x: x, y: y)
        case .hsplit(_, _, _, _, let children):
            let sizes = distribute(total: w, weights: children.map { max($0.width, 1) })
            var cx = x
            var out: [Node] = []
            for (child, cw) in zip(children, sizes) {
                out.append(renormalized(child, w: cw, h: h, x: cx, y: y))
                cx += cw + 1
            }
            return .hsplit(w: w, h: h, x: x, y: y, children: out)
        case .vsplit(_, _, _, _, let children):
            let sizes = distribute(total: h, weights: children.map { max($0.height, 1) })
            var cy = y
            var out: [Node] = []
            for (child, ch) in zip(children, sizes) {
                out.append(renormalized(child, w: w, h: ch, x: x, y: cy))
                cy += ch + 1
            }
            return .vsplit(w: w, h: h, x: x, y: y, children: out)
        }
    }

    /// Split `total` (minus n-1 divider cells) proportionally to `weights`,
    /// each part ≥1, rounding drift absorbed by the last part.
    static func distribute(total: Int, weights: [Int]) -> [Int] {
        let n = weights.count
        let available = max(total - (n - 1), n)   // ≥1 cell each
        let sum = weights.reduce(0, +)
        var out: [Int] = []
        var used = 0
        for (i, weight) in weights.enumerated() {
            if i == n - 1 {
                out.append(max(available - used, 1))
            } else {
                let share = max(Int((Double(available) * Double(weight) / Double(sum)).rounded()), 1)
                out.append(share)
                used += share
            }
        }
        return out
    }
}

// MARK: - Codable (persisted directly by the workspace store)

extension LayoutTree.Node: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, id, w, h, x, y, children
    }
    private enum Kind: String, Codable { case leaf, hsplit, vsplit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        let w = try c.decode(Int.self, forKey: .w)
        let h = try c.decode(Int.self, forKey: .h)
        let x = try c.decode(Int.self, forKey: .x)
        let y = try c.decode(Int.self, forKey: .y)
        switch kind {
        case .leaf:
            self = .leaf(id: try c.decode(Int.self, forKey: .id), w: w, h: h, x: x, y: y)
        case .hsplit:
            self = .hsplit(w: w, h: h, x: x, y: y,
                           children: try c.decode([LayoutTree.Node].self, forKey: .children))
        case .vsplit:
            self = .vsplit(w: w, h: h, x: x, y: y,
                           children: try c.decode([LayoutTree.Node].self, forKey: .children))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id, let w, let h, let x, let y):
            try c.encode(Kind.leaf, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        case .hsplit(let w, let h, let x, let y, let children):
            try c.encode(Kind.hsplit, forKey: .type)
            try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
            try c.encode(children, forKey: .children)
        case .vsplit(let w, let h, let x, let y, let children):
            try c.encode(Kind.vsplit, forKey: .type)
            try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
            try c.encode(children, forKey: .children)
        }
    }
}
