import BentoWorkbench
import Foundation

// The concrete wire shape behind stage 1's encoding seam: StructureVerb →
// the daemon's `structure` control frame, field for field against the Go
// decoder (daemon/internal/acphost: Control in proto.go, StructureVerb in
// tmuxstructure.go). Keys are snake_cased exactly as the Go json tags spell
// them; pane ids travel as bare ints (`%5` → 5); session names are tmux
// session names. Empty strings and false bools are omitted — the Go zero
// values they'd decode to anyway — while the ints a verb carries are always
// explicit, so pane %0 can never read as "field absent".

/// Encodes verbs for one tmux server target. `target` "" is omitted from
/// the frame (the daemon defaults it to "local", same as an absent field).
public struct DaemonStructureVerbEncoding: StructureVerbEncoding {
    public let target: String

    public init(target: String = "") {
        self.target = target
    }

    public func encodeStructureFrame(_ verb: StructureVerb) throws -> Data {
        let encoder = JSONEncoder()
        // Deterministic frames: the golden tests compare whole strings, and
        // a stable byte shape is worth having on the wire anyway.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Frame(op: "structure",
                                        target: target.isEmpty ? nil : target,
                                        verb: WireVerb(verb)))
    }

    private struct Frame: Encodable {
        let op: String
        let target: String?
        let verb: WireVerb
    }

    /// Mirror of the Go StructureVerb, encode-only. Every field optional:
    /// each verb writes exactly the associated values it carries.
    private struct WireVerb: Encodable {
        var kind: String
        var name: String?
        var to: String?
        var session: String?
        var cwd: String?
        var command: String?
        var target: Int?
        var pane: Int?
        var horizontal: Bool?
        var up: Bool?
        var a: Int?
        var b: Int?
        var source: Int?
        var at: Int?
        var before: Bool?
        var toSession: String?
        var direction: String?
        var amount: Int?
        var order: [Int]?

        enum CodingKeys: String, CodingKey {
            case kind, name, to, session, cwd, command, target, pane
            case horizontal, up, a, b, source, at, before
            case toSession = "to_session"
            case direction, amount, order
        }

        init(_ verb: StructureVerb) {
            func blankable(_ s: String?) -> String? {
                guard let s, !s.isEmpty else { return nil }
                return s
            }
            func flag(_ v: Bool) -> Bool? { v ? true : nil }

            switch verb {
            case .createSession(let name, let cwd):
                kind = "createSession"
                self.name = name
                self.cwd = blankable(cwd)
            case .killSession(let name):
                kind = "killSession"
                self.name = name
            case .renameSession(let name, let to):
                kind = "renameSession"
                self.name = name
                self.to = to
            case .splitPane(let session, let target, let horizontal, let cwd, let command):
                kind = "splitPane"
                self.session = blankable(session)
                self.target = target
                self.horizontal = flag(horizontal)
                self.cwd = blankable(cwd)
                self.command = blankable(command)
            case .newPane(let session, let cwd, let command):
                kind = "newPane"
                self.session = blankable(session)
                self.cwd = blankable(cwd)
                self.command = blankable(command)
            case .killPane(let pane):
                kind = "killPane"
                self.pane = pane
            case .selectPane(let pane):
                kind = "selectPane"
                self.pane = pane
            case .renamePane(let pane, let to):
                kind = "renamePane"
                self.pane = pane
                self.to = to
            case .toggleZoom(let pane):
                kind = "toggleZoom"
                self.pane = pane
            case .swapPane(let pane, let up):
                kind = "swapPane"
                self.pane = pane
                self.up = flag(up)
            case .swapPanes(let a, let b):
                kind = "swapPanes"
                self.a = a
                self.b = b
            case .dockPane(let source, let at, let horizontal, let before):
                kind = "dockPane"
                self.source = source
                self.at = at
                self.horizontal = flag(horizontal)
                self.before = flag(before)
            case .movePane(let pane, let toSession):
                kind = "movePane"
                self.pane = pane
                self.toSession = toSession
            case .resizePane(let pane, let direction, let amount):
                kind = "resizePane"
                self.pane = pane
                self.direction = direction
                self.amount = amount
            case .reorderPanes(let session, let order):
                kind = "reorderPanes"
                self.session = blankable(session)
                self.order = order
            case .applyTiled(let session):
                kind = "applyTiled"
                self.session = blankable(session)
            }
        }
    }
}
