import UIKit
import SwiftUI
import Combine
import BentoTerminalCore
import SwiftTmux

// MARK: - Pane content seam

/// The exact `TerminalContainerVC` subset `PaneContainerVC` calls, so pane
/// content is swappable: ACP-backed sessions host the agent chat
/// (`AgentChatVC`), SSH/direct hosts keep the terminal surface. Every member
/// here is one the container actually uses — nothing speculative.
@MainActor
protocol PaneContentController: UIViewController {
    var voiceController: VoiceInputController? { get set }
    var paneVM: PaneViewModel? { get }
    var titleBar: PaneTitleBar { get }
    var paneMenu: UIMenu { get }

    // Layout knobs the container drives per pass (tiled cell geometry vs
    // focus fill) — see PaneContainerVC.layoutPanes.
    var tiled: Bool { get set }
    var fixedTerminalCellSize: CGSize? { get set }
    var titleBarHeight: CGFloat { get set }
    var surfaceInsetX: CGFloat { get set }

    // Callbacks the container wires in addPaneController / setupSinglePane.
    var onSelectPaneTapped: (() -> Void)? { get set }
    var onSplitRequested: ((_ horizontal: Bool) -> Void)? { get set }
    var showsSplitActions: (() -> Bool)? { get set }
    var onCloseRequested: (() -> Void)? { get set }
    var onToggleZoom: (() -> Void)? { get set }
    var onSetProfile: ((_ profileID: String?) -> Void)? { get set }
    var currentProfileID: (() -> String?)? { get set }
    var moveTargets: (() -> [String])? { get set }
    var onMoveToSession: ((_ session: String) -> Void)? { get set }
    var onTitleDrag: ((_ phase: TitleDragPhase) -> Void)? { get set }
    var onSizeChanged: ((_ size: TerminalSurfaceSize) -> Void)? { get set }
    var pathPreviewContext: (() -> PathPreviewContext?)? { get set }

    /// The content's own cwd report (terminal: OSC 7; chat: the session's
    /// cwd) — the container's path-preview fallback.
    var reportedPwd: String? { get }

    func bindToPaneVM(_ vm: PaneViewModel)
    func bindToTerminalVM(_ vm: TerminalViewModel)
    func updatePaneState(_ state: PaneState, active: Bool)
    func teardown()
    func cursorRect(in target: UIView) -> CGRect?
    func handleAccessoryKey(_ key: AccessoryKey)
}

extension TerminalContainerVC: PaneContentController {
    /// The surface's OSC 7 report (the container used to reach through
    /// `surface` directly; the seam hides the engine).
    var reportedPwd: String? { surface?.reportedPwd }
}

// MARK: - Agent chat pane

/// Hosts one ACP agent conversation (`AgentChatView`) as pane content,
/// mimicking exactly the `TerminalContainerVC` subset the pane container
/// calls — so ACP panes show the agent chat while every piece of pane chrome
/// (title bar + state dot, tint wash, focus border, press-anywhere voice,
/// tiled cell geometry, floating-toolbar menu) behaves identically to a
/// terminal pane. The iOS sibling of `AgentChatSurface` (macOS).
final class AgentChatVC: UIViewController, PaneContentController {
    /// Fixed virtual cell for synthesizing a `TerminalSurfaceSize` from bounds
    /// (chat has no real grid; the container only needs stable, sane numbers).
    /// Same 8×17 the macOS chat surface uses.
    private static let virtualCellWidth: CGFloat = 8
    private static let virtualCellHeight: CGFloat = 17

    /// Runtime lookup: pane → agent session VM. The store owns runtimes; a
    /// pane can appear before its agent finished spawning, so the binding
    /// re-checks on every state push (AgentChatView shows the starting
    /// placeholder while nil).
    private let store: AgentWorkspaceStore
    private let chatModel = AgentChatModel()
    private var hosting: UIHostingController<AgentChatView>!
    let titleBar = PaneTitleBar()

    /// Translucent state wash over the chat, identical to the terminal pane's
    /// (working / awaiting read at a glance). Hit-test transparent.
    private let stateTint = UIView()
    private var cancellables = Set<AnyCancellable>()

    private(set) var paneVM: PaneViewModel?
    var terminalVM: TerminalViewModel?

    /// Voice gesture pipeline. Parent VC injects the controller; we just
    /// forward `handleLongPress` states — same as the terminal pane.
    weak var voiceController: VoiceInputController?

    // MARK: - Callbacks (set by parent — same declarations as TerminalContainerVC)

    var onSelectPaneTapped: (() -> Void)?
    var onSplitRequested: ((_ horizontal: Bool) -> Void)?
    var showsSplitActions: (() -> Bool)?
    var onCloseRequested: (() -> Void)?
    var onToggleZoom: (() -> Void)?
    var onSetProfile: ((_ profileID: String?) -> Void)?
    var currentProfileID: (() -> String?)?
    var moveTargets: (() -> [String])?
    var onMoveToSession: ((_ session: String) -> Void)?
    var onTitleDrag: ((_ phase: TitleDragPhase) -> Void)?
    var onSizeChanged: ((_ size: TerminalSurfaceSize) -> Void)?
    var pathPreviewContext: (() -> PathPreviewContext?)?

    var tiled = false {
        didSet { titleBar.isTiled = tiled }
    }

    /// In tiled mode the container hands the exact tmux cell geometry. The
    /// chat clamps to the visible tile instead of overflowing by one cell
    /// (that trick exists so ghostty's grid ≥ tmux; chat has no grid to
    /// protect and clipped text would just look broken).
    var fixedTerminalCellSize: CGSize? {
        didSet { view.setNeedsLayout() }
    }

    var titleBarHeight: CGFloat = TerminalContainerVC.defaultTitleBarHeight {
        didSet { if oldValue != titleBarHeight { view.setNeedsLayout() } }
    }

    var surfaceInsetX: CGFloat = 0 {
        didSet { if oldValue != surfaceInsetX { view.setNeedsLayout() } }
    }

    /// The session's working directory — the ACP analogue of OSC 7.
    var reportedPwd: String? { chatModel.session?.cwd }

    init(store: AgentWorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        setupHosting()
        setupTitleBar()
        attachGestures()
        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .terminalThemeChanged, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Re-seed follow-system from the HOST's trait, not our own — this
        // view's style is pinned to the theme canvas (override below), so its
        // trait says nothing about the OS appearance.
        if let host = parent?.traitCollection.userInterfaceStyle, host != .unspecified {
            ThemeStore.shared.updateSystemIsDark(host == .dark)
        }
        applyTheme()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let tbh = titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        // Tiled: the container grew half a divider cell into each side so
        // neighbours meet; keep the chat at the pane's true cell area.
        let insetX = fixedTerminalCellSize != nil ? surfaceInsetX : 0
        hosting.view.frame = CGRect(x: insetX, y: tbh,
                                    width: max(0, view.bounds.width - 2 * insetX),
                                    height: max(0, view.bounds.height - tbh))
        stateTint.frame = hosting.view.frame
        reportSizeIfNeeded()
    }

    /// Idempotent; chat holds no engine resources, but the container calls
    /// this on every pane close / screen dismiss, so honor the contract.
    func teardown() {
        sizeDebounce?.cancel()
        sizeDebounce = nil
        cancellables.removeAll()
    }

    // MARK: - Setup

    private func setupHosting() {
        let hosting = UIHostingController(rootView: AgentChatView(model: chatModel))
        hosting.view.backgroundColor = .clear
        // The pane container owns keyboard avoidance (it pans the content —
        // see cursorRect below); SwiftUI's own keyboard inset on top of that
        // pan would double-lift the composer.
        hosting.safeAreaRegions = .container
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        self.hosting = hosting

        // State wash above the chat (below the title bar, added next).
        stateTint.isUserInteractionEnabled = false
        stateTint.backgroundColor = .clear
        view.addSubview(stateTint)
    }

    private func setupTitleBar() {
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: titleBarHeight)
        titleBar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        titleBar.surfaceColor = view.backgroundColor ?? STTheme.term.bg
        view.addSubview(titleBar)

        // Drag the title bar onto another pane to swap/dock (tiled mode) —
        // identical wiring to the terminal pane.
        let titleDrag = UIPanGestureRecognizer(target: self, action: #selector(handleTitleDrag(_:)))
        titleBar.addGestureRecognizer(titleDrag)
    }

    @objc private func handleTitleDrag(_ g: UIPanGestureRecognizer) {
        // Window coordinates so the parent can hit-test across every pane.
        let win = g.location(in: nil)
        switch g.state {
        case .began:   onTitleDrag?(.began)
        case .changed: onTitleDrag?(.moved(win))
        case .ended:   onTitleDrag?(.ended(win))
        default:       onTitleDrag?(.cancelled)
        }
    }

    // MARK: - Theme

    @objc private func themeDidChange() {
        applyTheme()
        titleBar.recolor()
        applyPaneBorder(active: paneIsActive)
    }

    /// Sit the chat on the terminal theme's canvas: same background color as
    /// the terminal panes around it, with this subtree's appearance pinned
    /// light/dark by the canvas luminance so every system semantic color
    /// resolves legibly against it. Mirrors the macOS chat surface.
    private func applyTheme() {
        let theme = ThemeStore.shared.current
        chatModel.themeBackground = theme.bg
        let bgColor = theme.bgColor
        view.backgroundColor = bgColor
        titleBar.surfaceColor = bgColor
        let r = Double((theme.bg >> 16) & 0xFF) / 255
        let g = Double((theme.bg >> 8) & 0xFF) / 255
        let b = Double(theme.bg & 0xFF) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        overrideUserInterfaceStyle = luminance < 0.5 ? .dark : .light
    }

    // MARK: - Title & state

    func updatePaneState(_ state: PaneState, active: Bool) {
        // The runtime can appear after the pane did (agent still spawning);
        // this push runs on every layout/state pass, so late-attach here.
        attachRuntimeIfNeeded()
        titleBar.paneState = state
        titleBar.isActivePane = active
        applyPaneBorder(active: active)
        // Viewing the session clears its done-unseen badge (macOS setFocus).
        if active { chatModel.session?.markSeen() }
        UIView.animate(withDuration: 0.26) {
            self.stateTint.backgroundColor = state.tintUIColor ?? .clear
        }
    }

    /// Last-applied active state, so theme changes re-derive the border.
    private var paneIsActive = false

    /// Focus cue — byte-for-byte the terminal pane's rules: accent border on
    /// the active tile, hairline on the rest, none in focus/single layout.
    private func applyPaneBorder(active: Bool) {
        paneIsActive = active
        guard tiled else {
            view.layer.borderWidth = 0
            return
        }
        view.layer.borderWidth = active ? 2.0 : 0.5
        let faint = UIColor(white: STTheme.isLight ? 0 : 1, alpha: STTheme.isLight ? 0.09 : 0.06)
        view.layer.borderColor = (active ? view.tintColor : faint).cgColor
    }

    // MARK: - Binding

    func bindToPaneVM(_ vm: PaneViewModel) {
        paneVM = vm
        titleBar.titleLabel.text = vm.pane.currentCommand ?? "agent"
        attachRuntimeIfNeeded()
    }

    /// Non-tmux single pane (pre-attach). No pane → no runtime yet; the chat
    /// shows its starting placeholder until setupTmuxPanes rebuilds per-pane.
    func bindToTerminalVM(_ vm: TerminalViewModel) {
        terminalVM = vm
    }

    private func attachRuntimeIfNeeded() {
        guard chatModel.session == nil, let paneVM,
              let runtime = store.runtime(for: paneVM.paneID) else { return }
        chatModel.session = runtime
        titleBar.titleLabel.text = runtime.title
        cancellables.removeAll()
        // Chat panes have a real live title (the session's) — track it.
        runtime.$title
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] title in self?.titleBar.titleLabel.text = title }
            .store(in: &cancellables)
    }

    // MARK: - Keyboard avoidance

    /// nil → the container falls back to lifting the whole pane bottom above
    /// the keyboard, which is exactly right for chat (composer sits at the
    /// pane bottom; there is no mid-screen terminal cursor to chase).
    func cursorRect(in target: UIView) -> CGRect? { nil }

    // MARK: - Input (floating toolbar / accessory keys)

    /// Same key routing as the terminal pane, through the pane's send path
    /// (the ACP bridge lands text in the agent composer). Soft-Ctrl has no
    /// chat meaning; paste inserts into the composer directly.
    func handleAccessoryKey(_ key: AccessoryKey) {
        switch key {
        case .escape: sendString("\u{1B}")
        case .tab: sendString("\t")
        case .ctrl: break
        case .enter: sendString("\r")
        case .up: sendString("\u{1B}[A")
        case .down: sendString("\u{1B}[B")
        case .right: sendString("\u{1B}[C")
        case .left: sendString("\u{1B}[D")
        case .pipe: sendString("|")
        case .slash: sendString("/")
        case .tilde: sendString("~")
        case .dash: sendString("-")
        case .paste:
            if let text = UIPasteboard.general.string, !text.isEmpty {
                chatModel.session?.insertIntoComposer(text)
                chatModel.requestComposerFocus()
            }
        }
    }

    private func sendString(_ string: String) {
        if let paneVM { paneVM.sendString(string) }
        else { terminalVM?.sendString(string) }
    }

    // MARK: - Size synthesis

    private var lastReportedSize: TerminalSurfaceSize?
    private var sizeDebounce: DispatchWorkItem?

    /// Synthesize the authoritative-size report from bounds and the fixed
    /// virtual cell; debounced like the terminal surface so a rotation
    /// coalesces into one callback. Teaches the container its cellPx and, in
    /// focus mode, drives the client size — same plumbing, sane numbers.
    private func reportSizeIfNeeded() {
        let bounds = hosting.view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let size = TerminalSurfaceSize(
            columns: max(2, Int(bounds.width / Self.virtualCellWidth)),
            rows: max(2, Int(bounds.height / Self.virtualCellHeight)),
            cellWidthPx: Int(Self.virtualCellWidth * scale),
            cellHeightPx: Int(Self.virtualCellHeight * scale))
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        sizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onSizeChanged?(size) }
        sizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    // MARK: - Pane menu (floating toolbar)

    /// Split / Move to Session / Close — the terminal pane's menu minus
    /// Profile (detection profiles are terminal-only; ACP state is native).
    /// Deferred elements re-resolve at open, matching the terminal VC.
    private(set) lazy var paneMenu: UIMenu = makePaneMenu()

    private func makePaneMenu() -> UIMenu {
        let splitSection = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.showsSplitActions?() ?? true else {
                completion([])
                return
            }
            completion([
                UIAction(title: "Split Horizontal",
                         image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                    self?.onSplitRequested?(true)
                },
                UIAction(title: "Split Vertical",
                         image: UIImage(systemName: "rectangle.split.1x2")) { [weak self] _ in
                    self?.onSplitRequested?(false)
                },
            ])
        }
        let moveSection = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            var items: [UIMenuElement] = (self.moveTargets?() ?? []).map { name in
                UIAction(title: name) { [weak self] _ in
                    self?.onMoveToSession?(name)
                }
            }
            items.append(UIAction(title: "New Session…",
                                  image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.promptMoveToNewSession()
            })
            completion(items)
        }
        return UIMenu(children: [
            splitSection,
            UIMenu(title: "Move to Session",
                   image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                   children: [moveSection]),
            UIAction(title: "Close Pane",
                     image: UIImage(systemName: "xmark"),
                     attributes: .destructive) { [weak self] _ in
                self?.onCloseRequested?()
            },
        ])
    }

    private func promptMoveToNewSession() {
        let alert = UIAlertController(
            title: "Move to New Session",
            message: "The agent keeps running — it becomes a window of the new session.",
            preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Session name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Move", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text, !name.isEmpty else { return }
            self?.onMoveToSession?(name)
        })
        present(alert, animated: true)
    }
}

// MARK: - Gestures (press-anywhere voice + pane select)

extension AgentChatVC {
    /// Same recognizer set as the terminal surface, minus its scroll/selection
    /// machinery (the SwiftUI transcript scrolls itself):
    ///   - Voice press commits at 180ms (VoicePressGesture), prewarm on down.
    ///   - Single tap selects the pane (and passes through to SwiftUI).
    ///   - Double tap focuses the composer — the chat analogue of the
    ///     terminal's double-tap-to-compose.
    private func attachGestures() {
        let voicePress = VoicePressGesture(target: self, action: #selector(handleVoicePress(_:)))
        voicePress.delegate = self
        // Finger-down prewarm: overlap the mic engine's cold start with the
        // 180ms hold threshold, exactly like the terminal pane.
        voicePress.onTouchDown = { [weak self] in
            self?.voiceController?.prewarm()
        }
        hosting.view.addGestureRecognizer(voicePress)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.cancelsTouchesInView = false
        singleTap.delaysTouchesBegan = false
        singleTap.delaysTouchesEnded = false
        singleTap.delegate = self
        hosting.view.addGestureRecognizer(singleTap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        hosting.view.addGestureRecognizer(doubleTap)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        onSelectPaneTapped?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onSelectPaneTapped?()
        chatModel.requestComposerFocus()
    }

    @objc private func handleVoicePress(_ gesture: VoicePressGesture) {
        guard let controller = voiceController, let view = gesture.view else { return }
        // Selecting on press makes voice transcripts land on the right pane
        // even if the user starts holding on a non-active pane.
        if gesture.state == .began {
            onSelectPaneTapped?()
            // Bind the ASR context-biasing source to THIS pane's transcript
            // for the recording that's about to start.
            controller.readScreenText = { [weak self] in
                self?.chatModel.session?.recentTranscriptText
            }
        }
        let local = gesture.currentLocation()
        // VoiceInputController positions its overlay in screen (window)
        // coords, so convert before forwarding.
        let screen = view.convert(local, to: nil)
        controller.handleLongPress(state: gesture.state, location: screen)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension AgentChatVC: @preconcurrency UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Our tap / voice-press recognizers are passive and must coexist with
        // whatever SwiftUI installs on the hosting view (scroll, taps, …).
        return true
    }
}
