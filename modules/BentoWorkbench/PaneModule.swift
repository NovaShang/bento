import BentoFoundation
import BentoUI
import Foundation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Seam one's registration point: WHO builds the view inside a pane. The
// store owns lifecycle through `PaneRuntime`; this file owns the other half
// of the pane-module seam — kind identity, capability flags, and the surface
// factory the shells dispatch through instead of hardcoding a view class.
// Each app shell registers the modules its product ships (BentoMac: acp;
// the term shell: tmux); adding a pane kind is a new module + a register
// call, zero shell rewiring (docs/tmuxpane-design.md "PaneModule 注册").

/// What a pane holds. An open, string-backed kind (not a closed enum): the
/// registry dispatches on it, and a persisted blob from a NEWER build must
/// stay decodable on an older one (the unknown kind simply has no module).
/// Encodes as the bare raw string — the persisted/state wire shape is
/// unchanged from the enum era ("acp", "terminal", …).
///
/// Only `.acp` is user-creatable in product A today; the other names are
/// reserved seats (docs/hybrid-workbench-design.md): `.terminal` =
/// daemon-hosted pty, `.file` = preview, `.browser` = web, `.tmux` = a
/// daemon-hosted tmux pane (product B, docs/tmuxpane-design.md).
public struct PaneKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let acp = PaneKind(rawValue: "acp")
    public static let terminal = PaneKind(rawValue: "terminal")
    public static let file = PaneKind(rawValue: "file")
    public static let browser = PaneKind(rawValue: "browser")
    public static let tmux = PaneKind(rawValue: "tmux")
}

/// What a pane module's panes can DO — the flags shells key chrome and
/// input routing off, instead of testing concrete kinds.
public struct PaneCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// A daemon-hosted process lives behind the pane: restart / reattach /
    /// exit semantics apply (ACP agents, tmux panes, ptys).
    public static let hostedProcess = PaneCapabilities(rawValue: 1 << 0)
    /// The pane accepts routed text input (`AgentWorkspaceStore.routeInput`,
    /// the voice compass's insert vs send).
    public static let textInput = PaneCapabilities(rawValue: 1 << 1)
    /// The pane is anchored to a file/path (preview panes).
    public static let fileScoped = PaneCapabilities(rawValue: 1 << 2)
    /// The pane keeps its own back/forward history (browser, file tree).
    public static let navigable = PaneCapabilities(rawValue: 1 << 3)
    /// The pane can hold unsaved edits — closing should confirm.
    public static let dirtyState = PaneCapabilities(rawValue: 1 << 4)
    /// The pane's content needs explicit size round-trips to its host (the
    /// tmux `resize` op). ACP chat reflows locally and doesn't.
    public static let resizable = PaneCapabilities(rawValue: 1 << 5)
}

#if os(macOS)
/// The platform view a surface factory returns. The AppKit host embeds it
/// verbatim; kind-specific wiring stays with code that knows the concrete
/// class (see `TiledPaneHost.makeCell`).
public typealias PaneSurfaceView = NSView
#elseif canImport(UIKit)
/// iOS counterpart, unused until the iOS shell adopts the registry — its
/// PaneContainerVC/AgentChatVC path stays direct for now (stage-2 seam).
public typealias PaneSurfaceView = UIView
#endif

/// One pane kind's implementation, as the shells consume it: identity,
/// capability flags, and (macOS today) the surface factory. The runtime
/// half of a module still arrives through `AgentWorkspaceStore.runtimeFactory`
/// (installed per store by the module's `install`); folding that into this
/// protocol is deliberate stage-2 work — it changes the store's spawn path,
/// which stays frozen while product A is the only registrant.
@MainActor
public protocol PaneModule: AnyObject {
    var kind: PaneKind { get }
    var capabilities: PaneCapabilities { get }

    /// Build the view that renders `pane`. The store is handed over so the
    /// module can bind the pane's live runtime (`store.runtime(forPane:)`).
    /// Available on both platforms now (docs/term-ios-port.md): the iOS shell's
    /// generic `PaneContainerVC` embeds this surface inside its per-pane chrome
    /// cell exactly as the macOS host wraps the NSView. Kinds whose iOS content
    /// is a full view controller (the ACP chat) leave the default and are built
    /// through the shell's pane-VC factory instead.
    func makeSurface(for pane: PaneID, in store: AgentWorkspaceStore,
                     theme: CanvasTheme) -> PaneSurfaceView
}

@MainActor
public extension PaneModule {
    /// Default: an empty surface. A module supplies a real one only when its
    /// pane content is a plain view (the tmux terminal surface); the ACP chat
    /// pane rides the shell's view-controller factory and keeps the default.
    func makeSurface(for pane: PaneID, in store: AgentWorkspaceStore,
                     theme: CanvasTheme) -> PaneSurfaceView {
        PaneSurfaceView(frame: .zero)
    }
}

/// Kind → module table. Process-wide (`shared`) for the app shells — each
/// registers its product's modules at startup — and freshly constructible
/// for tests.
@MainActor
public final class PaneModuleRegistry {
    public static let shared = PaneModuleRegistry()

    private var modules: [PaneKind: any PaneModule] = [:]

    public init() {}

    /// Last registration for a kind wins (idempotent re-install).
    public func register(_ module: any PaneModule) {
        modules[module.kind] = module
    }

    public func module(for kind: PaneKind) -> (any PaneModule)? {
        modules[kind]
    }

    /// Surface for `pane`, dispatched on its persisted kind. nil when no
    /// module is registered for that kind (the caller owns the fallback —
    /// the Mac host keeps today's ACP construction as its default).
    public func makeSurface(for pane: PaneID, in store: AgentWorkspaceStore,
                            theme: CanvasTheme) -> PaneSurfaceView? {
        module(for: store.paneKind(pane.raw))?
            .makeSurface(for: pane, in: store, theme: theme)
    }
}
