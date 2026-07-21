import UIKit
import SwiftUI
import Combine
import BentoCore

/// Hosts one ACP agent conversation (`AgentChatView`) as pane content, with
/// the pane chrome (title bar + state dot, tint wash, focus border,
/// press-anywhere voice, tiled cell geometry). The iOS sibling of
/// `AgentChatSurface` (macOS).
final class AgentChatVC: UIViewController {
    /// Focus / single-pane title bar height (a comfortable touch target).
    static let defaultTitleBarHeight: CGFloat = 32

    /// Runtime lookup: pane → agent session VM. The store owns runtimes; a
    /// pane can appear before its agent finished spawning, so the binding
    /// re-checks on every state push (AgentChatView shows the starting
    /// placeholder while nil).
    private let store: AgentWorkspaceStore
    private let chatModel = AgentChatModel()
    private var hosting: UIHostingController<AgentChatView>!
    let titleBar = PaneTitleBar()

    /// Translucent state wash over the chat (working / awaiting read at a
    /// glance). Hit-test transparent.
    private let stateTint = UIView()
    private var cancellables = Set<AnyCancellable>()

    private(set) var paneVM: PaneViewModel?

    /// Voice gesture pipeline. Parent VC injects the controller; we just
    /// forward `handleLongPress` states.
    weak var voiceController: VoiceInputController?

    // MARK: - Callbacks (set by parent)

    var onSelectPaneTapped: (() -> Void)?
    var onTitleDrag: ((_ phase: TitleDragPhase) -> Void)?

    var tiled = false {
        didSet { titleBar.isTiled = tiled }
    }

    var titleBarHeight: CGFloat = AgentChatVC.defaultTitleBarHeight {
        didSet { if oldValue != titleBarHeight { view.setNeedsLayout() } }
    }

    /// Horizontal inset (points) of the chat inside the container, so
    /// abutting tiles read as separate panes. 0 = flush.
    var surfaceInsetX: CGFloat = 0 {
        didSet { if oldValue != surfaceInsetX { view.setNeedsLayout() } }
    }

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
        // Tiled: keep the chat at the pane's true area, inset so neighbours
        // read as separate panes.
        let insetX = tiled ? surfaceInsetX : 0
        hosting.view.frame = CGRect(x: insetX, y: tbh,
                                    width: max(0, view.bounds.width - 2 * insetX),
                                    height: max(0, view.bounds.height - tbh))
        stateTint.frame = hosting.view.frame
    }

    /// Idempotent; chat holds no engine resources, but the container calls
    /// this on every pane close / screen dismiss, so honor the contract.
    func teardown() {
        cancellables.removeAll()
    }

    // MARK: - Setup

    private func setupHosting() {
        let hosting = UIHostingController(rootView: AgentChatView(model: chatModel))
        hosting.view.backgroundColor = .clear
        // Chat owns its OWN keyboard avoidance (WeChat-style): SwiftUI's
        // keyboard safe-area inset shrinks the flexible transcript and lifts
        // the composer to the keyboard's top edge, while the title bar (a
        // sibling UIView) stays put. Hence the default `.all` safe-area
        // regions here — do NOT drop `.keyboard`.
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

        // Drag the title bar onto another pane to swap/dock (tiled mode).
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

    /// Sit the chat on the theme's canvas: same background color as the
    /// panes around it, with this subtree's appearance pinned light/dark by
    /// the canvas luminance so every system semantic color resolves legibly
    /// against it. Mirrors the macOS chat surface.
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

    /// Focus cue: accent border on the active tile, hairline on the rest,
    /// none in focus/single layout.
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

    private func attachRuntimeIfNeeded() {
        guard chatModel.session == nil, let paneVM,
              let runtime = store.runtime(forPane: paneVM.paneID.raw) else { return }
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
}

// MARK: - Gestures (press-anywhere voice + pane select)

extension AgentChatVC {
    /// Gesture set:
    ///   - Voice press commits after a short hold (VoicePressGesture),
    ///     prewarm on down.
    ///   - Single tap selects the pane (and passes through to SwiftUI).
    ///   - Double tap focuses the composer.
    private func attachGestures() {
        let voicePress = VoicePressGesture(target: self, action: #selector(handleVoicePress(_:)))
        voicePress.delegate = self
        // The SwiftUI ScrollView owns scrolling here and there's NO
        // scroll-vs-voice arbitration. The only thing that keeps a scroll
        // from becoming a voice press is the gesture failing on movement
        // during the arm window — so widen that window: a finger that rests
        // a beat before flicking has time to move and fail out instead of
        // committing to voice.
        voicePress.holdThreshold = 0.30
        // Finger-down prewarm: overlap the mic engine's cold start with the
        // hold threshold.
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
