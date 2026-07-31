#if canImport(UIKit)
import SwiftUI
import UIKit
import BentoFoundation
import BentoUI
import BentoWorkbench
import BentoFilePreviewKit

// Seam one, iOS half. On macOS the pane content is a plain `NSView` the host
// wraps in its own chrome cell; on iOS a pane's content is a full view
// controller (the ACP chat hosts a `UIHostingController`; the tmux terminal
// hosts an engine surface + accessory bars), so the generic `PaneContainerVC`
// drives per-pane VCs through THIS protocol and builds them through the
// `ShellPaneRegistry` factory the app composition root installs — the "pane →
// UIViewController factory" of docs/term-ios-port.md §1a. The workbench-level
// `PaneModuleRegistry.makeSurface` (extended to iOS) still vends the bare
// terminal surface the tmux pane VC embeds; this protocol lives here, not in
// BentoWorkbench, because it names shell types (voice / preview) the workbench
// may not import.

/// One pane's content view controller, as `PaneContainerVC` drives it. Product
/// A's `AgentChatVC` and product B's terminal pane VC both conform; the
/// container never names either concrete type.
@MainActor
public protocol PaneSurfaceController: UIViewController {
    /// Focus / single-pane title-bar height (a comfortable touch target).
    static var defaultTitleBarHeight: CGFloat { get }

    /// Injected by the container so the pane can forward hold-to-talk and open
    /// tapped file paths in the shared panel.
    var voiceController: VoiceInputController? { get set }
    var previewPresenter: FilePreviewPresenter? { get set }

    /// Container callbacks (set once, right after construction).
    var onSelectPaneTapped: (() -> Void)? { get set }
    var onTitleDrag: ((_ phase: TitleDragPhase) -> Void)? { get set }
    var onNewChat: (() -> Void)? { get set }
    var onFocusPane: (() -> Void)? { get set }
    var paneMenuProvider: (() -> [UIMenuElement])? { get set }

    /// Tiled (Parallel) vs. single-pane (Focus / zoomed) chrome + layout.
    var tiled: Bool { get set }
    var titleBarHeight: CGFloat { get set }
    /// Horizontal inset of the content inside the container, so abutting tiles
    /// read as separate panes.
    var surfaceInsetX: CGFloat { get set }

    /// Bind the pane's projection (title source) + late-attach its runtime.
    func bindToPaneVM(_ vm: PaneViewModel)
    /// Push the pane's status into the chrome (dot / wash / focus border).
    func updatePaneState(_ state: PaneState, doneUnseen: Bool, active: Bool)
    /// Set only the active-pane chrome flag (used by the focus-layout pass).
    func setActivePaneChrome(_ active: Bool)
    /// Release per-pane resources before the container drops the VC.
    func teardown()
}

/// The app composition root registers how a pane VC is built for its product:
/// `BentoIOS` installs `{ AgentChatVC(store: $0) }`, `BentoTermIOS` installs the
/// tmux terminal pane VC. One app ships one pane kind, so a single factory
/// suffices (the pane-KIND fan-out lives in `PaneModuleRegistry` on the surface
/// side). The generic `PaneContainerVC` reads it and never links either app.
@MainActor
public enum ShellPaneRegistry {
    /// Builds a pane VC bound to `store`. nil until the app installs one — the
    /// container then renders no panes (a misconfiguration, not a crash).
    public static var paneControllerFactory: ((AgentWorkspaceStore) -> PaneSurfaceController)?

    /// Resolves the active pane's file-preview context (cwd + host) for the
    /// Files tree root. A-specific: product A builds it from the ACP session's
    /// `makePreviewContext`; product B from the tmux pane's cwd. nil = the tree
    /// has no root until a file is tapped. Kept out of the generic screen so
    /// BentoShelliOS never imports a pane module.
    public static var previewContextProvider: ((AgentWorkspaceStore, PaneID) -> PathPreviewContext?)?

    /// How this product lets the user add a host — the `+` button's menu.
    ///
    /// A seam, because the two products reach a machine in genuinely different
    /// ways: Bento Agents pairs with a Mac daemon over the relay, Bento Term
    /// opens an SSH connection to anything with a shell. Offering both in both
    /// would put a pairing code in front of a terminal user and an SSH form in
    /// front of someone who has no sshd. Empty = the `+` button hides itself.
    public static var hostAddOptions: [HostAddOption] = []

    /// A banner for the state of the connection behind one workspace
    /// (host, workspace name), or nil when there is nothing to say.
    ///
    /// The screen cannot answer this itself: a workspace's view model knows
    /// whether IT is attached, not whether the transport under it is alive.
    /// Those went out of step exactly when it mattered — a dropped link left
    /// panes that looked idle rather than dead, with nothing on screen and only
    /// a log line to say otherwise. The pre-merge product drove such a banner
    /// off its own `isReconnecting` for this reason.
    public static var connectionBanner: ((Host, String) -> AnyView?)?

    /// This product's first-run screen, shown when there are no hosts yet.
    /// nil = the built-in pairing flow (product A's).
    ///
    /// Same seam as `hostAddOptions` and for the same reason, one screen
    /// earlier: the built-in one teaches "install the Bento app on a Mac, come
    /// back, scan its QR", which is a daemon Bento Term does not have and an
    /// install it does not need. A terminal user's first screen has to name
    /// what is actually true — a host they can already `ssh` to.
    ///
    /// `addHost` opens the same sheet the `+` button does, driven by the host
    /// list. Passed in rather than owned by the welcome screen because a sheet
    /// presented from inside the empty-state branch does not survive that
    /// branch re-rendering, and silently never appears.
    public static var welcomeFlow: ((_ addHost: @escaping () -> Void) -> AnyView)?
}

/// One entry in the `+` menu: what it is called, and the sheet it opens.
public struct HostAddOption: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// Builds the sheet. `dismiss` closes it.
    public let sheet: (@escaping () -> Void) -> AnyView

    public init(id: String, title: String, systemImage: String,
                sheet: @escaping (@escaping () -> Void) -> AnyView) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.sheet = sheet
    }
}
#endif
