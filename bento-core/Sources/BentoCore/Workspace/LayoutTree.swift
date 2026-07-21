import Foundation

/// Bento's split-pane layout model: a tree of fractional rects on a unit
/// canvas ([0,1]×[0,1]) — pure proportions, no terminal cells, no divider
/// columns. This is the workspace's own geometry (no external multiplexer
/// involved) — the store persists the tree directly (Codable) and every
/// structure verb below returns a fully renormalized tree (sizes + offsets
/// recomputed).
///
/// History: the tree used to live on an integer character-cell canvas
/// (160×48 by default) with one-cell dividers. The model is now
/// fractional; that era survives only in two compatibility shims:
///  - `frames(of:)` projects fractions onto the legacy 160×48 grid for
///    consumers that still traffic in Int "cells" (`Pane.width` etc.).
///  - `resizing(amount:)` interprets one "cell" as 1/160 (horizontal) or
///    1/48 (vertical) of the canvas.
/// Old persisted trees (absolute cell coordinates) are detected by their
/// out-of-unit root extent and canonicalized on first touch.
public enum LayoutTree {
    /// Legacy projection grid, and the unit of the Int-amount resize shim.
    public static let legacyCols = 160
    public static let legacyRows = 48
    /// No pane may shrink below this fraction of the canvas on either axis.
    static let minShare = 0.02

    public indirect enum Node: Equatable, Sendable {
        case leaf(id: Int, w: Double, h: Double, x: Double, y: Double)
        case hsplit(w: Double, h: Double, x: Double, y: Double, children: [Node])
        case vsplit(w: Double, h: Double, x: Double, y: Double, children: [Node])

        var width: Double {
            switch self {
            case .leaf(_, let w, _, _, _), .hsplit(let w, _, _, _, _), .vsplit(let w, _, _, _, _): return w
            }
        }
        var height: Double {
            switch self {
            case .leaf(_, _, let h, _, _), .hsplit(_, let h, _, _, _), .vsplit(_, let h, _, _, _): return h
            }
        }
    }

    // MARK: - Canvas

    /// A fresh single-pane layout filling the unit canvas. `w`/`h` are
    /// ignored (legacy-signature shim — callers used to pass cell sizes).
    public static func single(pane id: Int, w: Int = 0, h: Int = 0) -> Node {
        .leaf(id: id, w: 1, h: 1, x: 0, y: 0)
    }

    /// Renormalize a tree to the unit canvas. `w`/`h` are ignored (legacy
    /// shim — the canvas is always [0,1]); kept because callers still pass
    /// their vestigial cols/rows. Also heals legacy cell trees.
    public static func resized(_ node: Node, w: Int, h: Int) -> Node {
        renormalized(canonical(node), w: 1, h: 1, x: 0, y: 0)
    }

    /// Convert a legacy absolute-cell tree (root extent ≫ 1) to unit
    /// fractions. Proportions are preserved; the old one-cell divider gaps
    /// are absorbed by the renormalize pass. Unit trees pass through.
    static func canonical(_ node: Node) -> Node {
        guard node.width > 1.5 || node.height > 1.5 else { return node }
        let sw = node.width > 0 ? 1.0 / node.width : 1
        let sh = node.height > 0 ? 1.0 / node.height : 1
        func scale(_ n: Node) -> Node {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                return .leaf(id: id, w: w * sw, h: h * sh, x: x * sw, y: y * sh)
            case .hsplit(let w, let h, let x, let y, let c):
                return .hsplit(w: w * sw, h: h * sh, x: x * sw, y: y * sh, children: c.map(scale))
            case .vsplit(let w, let h, let x, let y, let c):
                return .vsplit(w: w * sw, h: h * sh, x: x * sw, y: y * sh, children: c.map(scale))
            }
        }
        return renormalized(scale(node), w: 1, h: 1, x: 0, y: 0)
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

    /// Every leaf's fractional frame on the unit canvas, keyed by pane id.
    public static func fractions(of node: Node) -> [Int: (w: Double, h: Double, x: Double, y: Double)] {
        var out: [Int: (w: Double, h: Double, x: Double, y: Double)] = [:]
        func walk(_ n: Node) {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                out[id] = (w, h, x, y)
            case .hsplit(_, _, _, _, let children), .vsplit(_, _, _, _, let children):
                children.forEach(walk)
            }
        }
        walk(canonical(node))
        return out
    }

    /// Every leaf's frame projected onto the legacy 160×48 Int grid — the
    /// compatibility read for consumers that still speak "cells". Edges are
    /// projected (not sizes) so neighbors always tile exactly: shared
    /// boundaries round identically, no gaps or overlaps.
    public static func frames(of node: Node) -> [Int: (w: Int, h: Int, x: Int, y: Int)] {
        var out: [Int: (w: Int, h: Int, x: Int, y: Int)] = [:]
        let cols = Double(legacyCols), rows = Double(legacyRows)
        for (id, f) in fractions(of: node) {
            let xL = Int((f.x * cols).rounded())
            let xR = Int(((f.x + f.w) * cols).rounded())
            let yT = Int((f.y * rows).rounded())
            let yB = Int(((f.y + f.h) * rows).rounded())
            out[id] = (w: max(xR - xL, 1), h: max(yB - yT, 1), x: xL, y: yT)
        }
        return out
    }

    // MARK: - Split (split a target pane's rect along an axis)

    /// Split `target`'s rect in two equal halves along the given axis and
    /// put `newID` in the second half (`newFirst` puts it in the first half
    /// instead — the "dock before" case). `horizontal` = side by side.
    /// Same-axis nesting is flattened into the parent container (canonical
    /// form). nil when `target` is missing or `newID` already used.
    public static func splitting(pane target: Int, adding newID: Int, horizontal: Bool,
                                 newFirst: Bool = false, in tree: Node) -> Node? {
        let node = canonical(tree)
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
                    let half = w / 2
                    let a = Node.leaf(id: newFirst ? newID : id, w: half, h: h, x: x, y: y)
                    let b = Node.leaf(id: newFirst ? id : newID, w: half, h: h, x: x + half, y: y)
                    return .hsplit(w: w, h: h, x: x, y: y, children: [a, b])
                } else {
                    let half = h / 2
                    let a = Node.leaf(id: newFirst ? newID : id, w: w, h: half, x: x, y: y)
                    let b = Node.leaf(id: newFirst ? id : newID, w: w, h: half, x: x, y: y + half)
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
        return renormalized(rebuild(node), w: 1, h: 1, x: 0, y: 0)
    }

    // MARK: - Remove

    /// Remove a pane's leaf; its rect collapses into a sibling (the container
    /// renormalizes, so the space is shared proportionally — visually the
    /// neighbors absorb it). Returns nil when the pane isn't present or it
    /// was the only leaf.
    public static func removing(pane id: Int, from tree: Node) -> Node? {
        let node = canonical(tree)
        guard let pruned = prune(id, node) else { return nil }
        return renormalized(pruned, w: 1, h: 1, x: 0, y: 0)
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
    public static func inserting(pane id: Int, into tree: Node) -> Node {
        let node = canonical(tree)
        guard let target = largestLeaf(node),
              let split = splitting(pane: target, adding: id,
                                    horizontal: preferHorizontal(target, in: node),
                                    in: node) else { return node }
        return split
    }

    private static func largestLeaf(_ node: Node) -> Int? {
        var best: (id: Int, area: Double)?
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

    /// "Longer edge" is judged on the legacy canvas aspect (160×48 ≈ a real
    /// window's shape), not the square unit canvas — this preserves the old
    /// column-first insertion pattern (a half-width pane still reads wider
    /// than full height).
    private static func preferHorizontal(_ id: Int, in node: Node) -> Bool {
        guard let frame = fractions(of: node)[id] else { return true }
        return frame.w * Double(legacyCols) >= frame.h * Double(legacyRows)
    }

    // MARK: - Swap (content follows ids, geometry stays)

    /// Exchange two panes' positions. Geometry is untouched — only the ids
    /// trade places.
    public static func swapping(_ a: Int, _ b: Int, in tree: Node) -> Node {
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
        return rebuild(canonical(tree))
    }

    /// The pane before / after `id` in depth-first leaf order, wrapping.
    public static func neighbor(of id: Int, previous: Bool, in node: Node) -> Int? {
        let order = leafOrder(of: node)
        guard order.count > 1, let idx = order.firstIndex(of: id) else { return nil }
        let n = order.count
        return order[((idx + (previous ? -1 : 1)) % n + n) % n]
    }

    // MARK: - Resize (move a pane's border)

    /// Move `id`'s border in `direction` ("L"/"R"/"U"/"D") by `amount` legacy
    /// cells — one cell = 1/160 of the canvas horizontally, 1/48 vertically
    /// (the shim that keeps Int-speaking callers working): R = right border
    /// right (grow), L = right border left (shrink), and the vertical pair
    /// likewise — falling back to the opposite border when the pane has no
    /// sibling on that side. Unchanged tree when nothing can move.
    public static func resizing(pane id: Int, direction: String, amount: Int, in tree: Node) -> Node {
        guard amount > 0 else { return tree }
        let node = canonical(tree)
        let horizontal = (direction == "L" || direction == "R")
        let grow = (direction == "R" || direction == "D")
        let step = Double(amount) / Double(horizontal ? legacyCols : legacyRows)
        guard let adjusted = adjustBoundary(pane: id, horizontal: horizontal,
                                            delta: grow ? step : -step, in: node) else {
            return node
        }
        return renormalized(adjusted, w: 1, h: 1, x: 0, y: 0)
    }

    /// Grow/shrink the subtree containing `pane` along an axis by `delta`
    /// (a canvas fraction), compensating the next sibling (or the previous
    /// one when the subtree is the container's last child). Both stay ≥
    /// `minShare`. nil = no ancestor on that axis.
    private static func adjustBoundary(pane id: Int, horizontal: Bool,
                                       delta: Double, in node: Node) -> Node? {
        func extent(_ n: Node) -> Double { horizontal ? n.width : n.height }

        /// Overwrite a node's own extent (children untouched — a following
        /// renormalize redistributes them).
        func withExtent(_ n: Node, _ e: Double) -> Node {
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
                    let d = max(min(delta, theirs - minShare), minShare - mine)
                    guard abs(d) > .ulpOfOne else { return (n, true) }
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
                    let d = max(min(delta, theirs - minShare), minShare - mine)
                    guard abs(d) > .ulpOfOne else { return (n, true) }
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
    /// everything" arrangement. `cols`/`rows` are ignored (legacy shim).
    public static func tiledPreset(panes: [Int], cols: Int = 0, rows: Int = 0) -> Node? {
        guard let first = panes.first else { return nil }
        guard panes.count > 1 else {
            return .leaf(id: first, w: 1, h: 1, x: 0, y: 0)
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
                rowsNodes.append(.hsplit(w: 1, h: 1, x: 0, y: 0, children: leaves))
            }
        }
        let root: Node
        if rowsNodes.count == 1 {
            root = rowsNodes[0]
        } else {
            root = .vsplit(w: 1, h: 1, x: 0, y: 0, children: rowsNodes)
        }
        return renormalized(root, w: 1, h: 1, x: 0, y: 0)
    }

    // MARK: - Renormalize

    /// Recompute every node's size and offset: distribute each container's
    /// extent to its children proportionally to their previous sizes,
    /// recursively. No divider space — dividers are a view concern now.
    static func renormalized(_ node: Node, w: Double, h: Double, x: Double, y: Double) -> Node {
        switch node {
        case .leaf(let id, _, _, _, _):
            return .leaf(id: id, w: w, h: h, x: x, y: y)
        case .hsplit(_, _, _, _, let children):
            let sizes = distribute(total: w, weights: children.map { max($0.width, .ulpOfOne) })
            var cx = x
            var out: [Node] = []
            for (child, cw) in zip(children, sizes) {
                out.append(renormalized(child, w: cw, h: h, x: cx, y: y))
                cx += cw
            }
            return .hsplit(w: w, h: h, x: x, y: y, children: out)
        case .vsplit(_, _, _, _, let children):
            let sizes = distribute(total: h, weights: children.map { max($0.height, .ulpOfOne) })
            var cy = y
            var out: [Node] = []
            for (child, ch) in zip(children, sizes) {
                out.append(renormalized(child, w: w, h: ch, x: x, y: cy))
                cy += ch
            }
            return .vsplit(w: w, h: h, x: x, y: y, children: out)
        }
    }

    /// Split `total` proportionally to `weights`; drift lands on the last
    /// part so the parts always sum to `total` exactly.
    static func distribute(total: Double, weights: [Double]) -> [Double] {
        let n = weights.count
        guard n > 0 else { return [] }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return Array(repeating: total / Double(n), count: n) }
        var out: [Double] = []
        var used = 0.0
        for (i, weight) in weights.enumerated() {
            if i == n - 1 {
                out.append(max(total - used, 0))
            } else {
                let share = total * weight / sum
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
        // Doubles decode legacy Int cell values too; `canonical` detects and
        // rescales whole legacy trees on first touch.
        let w = try c.decode(Double.self, forKey: .w)
        let h = try c.decode(Double.self, forKey: .h)
        let x = try c.decode(Double.self, forKey: .x)
        let y = try c.decode(Double.self, forKey: .y)
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
