import UIKit
import Combine
import BentoShelliOS
import BentoWorkbench
import BentoUI
import BentoTmuxPane

/// Product B's pane content: one tmux virtual instance rendered on the trunk
/// engine terminal surface, with the shared pane chrome (title bar + state dot,
/// tint wash, focus border, press-anywhere voice, tiled cell geometry). The
/// tmux twin of product A's `AgentChatVC`, and its `PaneSurfaceController` — the
/// generic `PaneContainerVC` (BentoShelliOS) drives it through that protocol and
/// builds it via the `ShellPaneRegistry` factory `TmuxShell` installs.
///
/// The terminal surface itself comes from `PaneModuleRegistry.makeSurface`
/// (→ `TmuxPaneModule`, bound to the pane's `TmuxPaneRuntime` byte streams). The
/// keyboard accessory / floating quick-keys are B-only chrome layered on top.
final class TermPaneVC: UIViewController, PaneSurfaceController {
    static let defaultTitleBarHeight: CGFloat = 32

    private let store: AgentWorkspaceStore
    let titleBar = PaneTitleBar()

    /// The engine terminal surface, built lazily once the pane is bound (the
    /// runtime can appear after the pane record does).
    private var surface: UIView?
    private let stateTint = UIView()
    private var cancellables = Set<AnyCancellable>()

    private(set) var paneVM: PaneViewModel?

    // MARK: PaneSurfaceController

    weak var voiceController: VoiceInputController?
    weak var previewPresenter: FilePreviewPresenter?

    var onSelectPaneTapped: (() -> Void)?
    var onTitleDrag: ((_ phase: TitleDragPhase) -> Void)?
    var onNewChat: (() -> Void)?
    var onFocusPane: (() -> Void)?
    var paneMenuProvider: (() -> [UIMenuElement])?

    var tiled = false {
        didSet {
            guard oldValue != tiled else { return }
            titleBar.isTiled = tiled
        }
    }

    var titleBarHeight: CGFloat = TermPaneVC.defaultTitleBarHeight {
        didSet { if oldValue != titleBarHeight { view.setNeedsLayout() } }
    }

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
        view.backgroundColor = STTheme.term.bg
        stateTint.isUserInteractionEnabled = false
        setupTitleBar()
        attachGestures()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .terminalThemeChanged, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let tbh = titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        let insetX = tiled ? surfaceInsetX : 0
        let frame = CGRect(x: insetX, y: tbh,
                           width: max(0, view.bounds.width - 2 * insetX),
                           height: max(0, view.bounds.height - tbh))
        surface?.frame = frame
        stateTint.frame = frame
    }

    func teardown() {
        cancellables.removeAll()
    }

    // MARK: - Setup

    private func setupTitleBar() {
        titleBar.surfaceColor = view.backgroundColor ?? STTheme.term.bg
        view.addSubview(stateTint)
        view.addSubview(titleBar)
        titleBar.onNewChat = { [weak self] in
            self?.onSelectPaneTapped?()
            self?.onNewChat?()
        }
        titleBar.onFocus = { [weak self] in
            self?.onSelectPaneTapped?()
            self?.onFocusPane?()
        }
        titleBar.menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                self?.onSelectPaneTapped?()
                completion(self?.paneMenuProvider?() ?? [])
            }
        ])
        let titleTap = UITapGestureRecognizer(target: self, action: #selector(handleTitleTap))
        titleBar.addGestureRecognizer(titleTap)
        let titleDrag = UIPanGestureRecognizer(target: self, action: #selector(handleTitleDrag(_:)))
        titleBar.addGestureRecognizer(titleDrag)
    }

    @objc private func handleTitleTap() { onSelectPaneTapped?() }

    @objc private func handleTitleDrag(_ g: UIPanGestureRecognizer) {
        let win = g.location(in: nil)
        switch g.state {
        case .began:   onTitleDrag?(.began)
        case .changed: onTitleDrag?(.moved(win))
        case .ended:   onTitleDrag?(.ended(win))
        default:       onTitleDrag?(.cancelled)
        }
    }

    @objc private func themeDidChange() {
        view.backgroundColor = STTheme.term.bg
        titleBar.surfaceColor = STTheme.term.bg
        titleBar.recolor()
    }

    // MARK: - PaneSurfaceController

    func setActivePaneChrome(_ active: Bool) {
        titleBar.isActivePane = active
    }

    func updatePaneState(_ state: PaneState, doneUnseen: Bool, active: Bool) {
        ensureSurface()
        titleBar.paneState = state
        titleBar.agentFinishedUnseen = doneUnseen
        titleBar.isActivePane = active
        applyPaneBorder(active: active)
        UIView.animate(withDuration: 0.26) {
            self.stateTint.backgroundColor = state.tintUIColor ?? .clear
        }
    }

    private func applyPaneBorder(active: Bool) {
        guard tiled else { view.layer.borderWidth = 0; return }
        view.layer.borderWidth = active ? 2.0 : 0.5
        let faint = UIColor(white: STTheme.isLight ? 0 : 1, alpha: STTheme.isLight ? 0.09 : 0.06)
        view.layer.borderColor = (active ? view.tintColor : faint).cgColor
    }

    func bindToPaneVM(_ vm: PaneViewModel) {
        paneVM = vm
        cancellables.removeAll()
        vm.$pane
            .map(\.chromeTitle)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] title in self?.titleBar.titleLabel.text = title }
            .store(in: &cancellables)
        ensureSurface()
    }

    /// Build the terminal surface once the pane is known. `makeSurface` binds it
    /// to the pane's `TmuxPaneRuntime` (byte streams both ways) inside the
    /// registry — the VC only hosts + lays it out.
    private func ensureSurface() {
        guard surface == nil, let vm = paneVM else { return }
        let made = PaneModuleRegistry.shared.makeSurface(
            for: vm.paneID, in: store, theme: ThemeStore.shared.makeCanvasTheme())
        guard let made else { return }
        surface = made
        view.insertSubview(made, belowSubview: stateTint)
        view.setNeedsLayout()
    }

    // MARK: - Gestures (press-anywhere voice + pane select)

    private func attachGestures() {
        let voicePress = VoicePressGesture(target: self, action: #selector(handleVoicePress(_:)))
        voicePress.delegate = self
        voicePress.holdThreshold = 0.25
        voicePress.onTouchDown = { [weak self] in self?.voiceController?.prewarm() }
        view.addGestureRecognizer(voicePress)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.cancelsTouchesInView = false
        singleTap.delegate = self
        view.addGestureRecognizer(singleTap)
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) { onSelectPaneTapped?() }

    @objc private func handleVoicePress(_ gesture: VoicePressGesture) {
        guard let controller = voiceController, let view = gesture.view else { return }
        if gesture.state == .began { onSelectPaneTapped?() }
        let local = gesture.currentLocation()
        let screen = view.convert(local, to: nil)
        controller.handleLongPress(state: gesture.state, location: screen)
    }
}

extension TermPaneVC: @preconcurrency UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
