import SwiftUI
import SwiftTmux
import BentoTerminalCore

/// Bridges the UIKit terminal views into SwiftUI navigation.
/// The TerminalViewModel and VoiceInputController are owned by the parent
/// (HostSessionsView) and passed in — the session has already been picked
/// before this view is pushed.
struct TerminalWrapperView: View {
    @ObservedObject var viewModel: TerminalViewModel
    @ObservedObject var voiceController: VoiceInputController

    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var showOnboarding: Bool = GestureOnboardingOverlay.shouldShow

    private var host: Host { viewModel.host }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            SinglePaneSurface(viewModel: viewModel, voiceController: voiceController)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(true)
        .overlay {
            if voiceController.showOverlay {
                GeometryReader { _ in
                    VoiceOverlayView(
                        transcript: voiceController.transcript,
                        activeDirection: voiceController.activeDirection,
                        isRecording: voiceController.isRecording
                    )
                    .position(
                        x: voiceController.fingerScreenPosition.x,
                        y: voiceController.fingerScreenPosition.y
                    )
                }
                .ignoresSafeArea()
                .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay {
            if showOnboarding, case .connected = viewModel.connectionState {
                GestureOnboardingOverlay {
                    GestureOnboardingOverlay.markDismissed()
                    withAnimation { showOnboarding = false }
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Connection Error", isPresented: $viewModel.showError) {
            Button("Dismiss", role: .cancel) { dismiss() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Sessions")
                        .font(.body)
                }
            }

            Spacer()

            VStack(spacing: 1) {
                Text(host.displayName)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    connectionDot
                    Text(host.hostname)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                if viewModel.isTmuxReady {
                    Button(action: { viewModel.splitPane(horizontal: true) }) {
                        Label("Split Horizontal", systemImage: "rectangle.split.2x1")
                    }
                    Button(action: { viewModel.splitPane(horizontal: false) }) {
                        Label("Split Vertical", systemImage: "rectangle.split.1x2")
                    }
                    Divider()
                    Button(action: { viewModel.resetTmuxClientToDeviceSize() }) {
                        Label("Fit Tmux to Device", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Divider()
                    Button(action: { viewModel.newWindow() }) {
                        Label("New Window", systemImage: "plus.rectangle")
                    }
                    if viewModel.windows.count > 1 {
                        Divider()
                        ForEach(viewModel.windows) { window in
                            Button(window.name) { viewModel.selectWindow(window.id) }
                        }
                    }
                    Divider()
                    Button(role: .destructive, action: {
                        viewModel.killSession()
                        dismiss()
                    }) {
                        Label("Kill Session", systemImage: "xmark.circle")
                    }
                    Divider()
                }
                Button(action: { showSettings = true }) {
                    Label("Settings", systemImage: "gear")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var connectionDot: some View {
        switch viewModel.connectionState {
        case .connected:
            Circle().fill(.green).frame(width: 5, height: 5)
        case .connecting:
            ProgressView().scaleEffect(0.5)
        case .failed:
            Circle().fill(.red).frame(width: 5, height: 5)
        case .disconnected:
            Circle().fill(.secondary).frame(width: 5, height: 5)
        }
    }
}

// MARK: - Single-pane surface

/// SwiftUI bridge for the UIKit container that hosts one active pane plus the
/// floating quick-keys toolbar. Other panes (tmux multi-pane sessions) stay
/// alive as hidden child VCs so their SwiftTerm scrollback survives switching.
struct SinglePaneSurface: UIViewControllerRepresentable {
    @ObservedObject var viewModel: TerminalViewModel
    @ObservedObject var voiceController: VoiceInputController

    /// Observe stateVersion so SwiftUI triggers updateUIViewController on state polls.
    var stateVersion: Int { viewModel.stateVersion }

    func makeUIViewController(context: Context) -> ActivePaneContainerVC {
        let vc = ActivePaneContainerVC()
        vc.viewModel = viewModel
        vc.voiceController = voiceController

        if viewModel.isTmuxReady {
            vc.setupTmuxPanes()
        } else {
            vc.setupSinglePane()
            Task { @MainActor in
                if case .disconnected = viewModel.connectionState {
                    await viewModel.connect()
                }
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: ActivePaneContainerVC, context: Context) {
        if viewModel.isTmuxReady {
            // Transition from single (non-tmux) to tmux-managed panes if needed.
            if vc.singlePaneVC != nil {
                vc.setupTmuxPanes()
            } else {
                vc.refreshPanes()
            }
        }
    }
}

// MARK: - Active Pane Container

/// Hosts one visible terminal pane plus the floating quick-keys toolbar.
///
/// Single-pane-at-a-time model: in tmux multi-pane sessions, all panes live as
/// hidden child VCs (so SwiftTerm scrollback survives switching), and only
/// `viewModel.activePaneID` is visible. The on-screen layout is identical to
/// non-tmux mode — one terminal filling the area minus the floating toolbar
/// reserve at the bottom.
final class ActivePaneContainerVC: UIViewController {
    var viewModel: TerminalViewModel?
    var voiceController: VoiceInputController?

    /// Tmux-mode pane controllers (one per tmux pane). All alive; only the
    /// active one is unhidden.
    private(set) var paneControllers: [TmuxPaneID: TerminalContainerVC] = [:]

    /// Non-tmux mode single pane controller, bound directly to TerminalViewModel.
    private(set) var singlePaneVC: TerminalContainerVC?

    private let floatingToolbar = FloatingQuickKeysToolbar()

    /// Bottom inset from the on-screen keyboard, in this view's coordinates.
    private var keyboardInsetBottom: CGFloat = 0

    /// Cache the last `cols × rows` we pushed to tmux so we don't spam the
    /// control channel from incidental layout passes. SwiftTerm fires its
    /// `sizeChanged` for every laid-out pane (active + hidden siblings get
    /// the same frame), so we'd otherwise send N identical refresh-client
    /// commands per layout.
    private var lastTmuxClientSize: (cols: Int, rows: Int)?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term.bg
        setupFloatingToolbar()
        setupKeyboardObservers()
        NotificationCenter.default.addObserver(
            self, selector: #selector(activePaneAppearanceChanged),
            name: .terminalThemeChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Sync the container's background with the active pane's background so
    /// the area outside the pane (safe-area strip below the floating toolbar,
    /// gaps above/below the toolbar itself) blends with the terminal instead
    /// of cutting through with a default dark color.
    ///
    /// Animates with the same 0.26s curve the pane VC uses for its own state
    /// tint transitions — keeps the surfaces in lockstep.
    private func syncBackgroundToActivePane() {
        let bg = activePaneVC?.view.backgroundColor ?? STTheme.term.bg
        guard view.backgroundColor != bg else { return }
        UIView.animate(withDuration: 0.26) {
            self.view.backgroundColor = bg
        }
    }

    @objc private func activePaneAppearanceChanged() {
        // Pane VC's own theme handler fires first via the same notification;
        // dispatch async so we read the updated color after it lands.
        DispatchQueue.main.async { [weak self] in
            self?.syncBackgroundToActivePane()
        }
    }

    private func setupFloatingToolbar() {
        floatingToolbar.onKeyTap = { [weak self] key in
            self?.activePaneVC?.handleAccessoryKey(key)
        }
        floatingToolbar.isHidden = true  // shown after first pane appears
        view.addSubview(floatingToolbar)
    }

    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        guard let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let inView = view.convert(frameValue, from: nil)
        keyboardInsetBottom = max(0, view.bounds.maxY - inView.minY)
        animateForKeyboard(note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardInsetBottom = 0
        animateForKeyboard(note)
    }

    private func animateForKeyboard(_ note: Notification) {
        let info = note.userInfo
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 0
        let opts = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: opts) {
            self.layoutSurface(animated: false)
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Active VC

    var activePaneVC: TerminalContainerVC? {
        if let single = singlePaneVC { return single }
        guard let activeID = viewModel?.activePaneID else {
            // No tmux active id yet — fall back to the first pane if any exist
            // so something is visible.
            return paneControllers.values.first
        }
        return paneControllers[activeID]
    }

    // MARK: - Pane lifecycle (non-tmux)

    func setupSinglePane() {
        guard let viewModel else { return }
        let vc = makeContainerVC()
        vc.bindToTerminalVM(viewModel)
        vc.titleBar.isActivePane = true
        // No tmux concept of splits in non-tmux mode — hide tmux-only menu
        // items (Split / Close). The host's top-bar menu still has Settings.
        vc.titleBar.menuButton.isHidden = true
        vc.titleBar.maximizeButton.isHidden = true

        addChild(vc)
        view.insertSubview(vc.view, belowSubview: floatingToolbar)
        vc.didMove(toParent: self)

        singlePaneVC = vc
        floatingToolbar.isHidden = false
        layoutSurface(animated: false)
        syncBackgroundToActivePane()
    }

    // MARK: - Pane lifecycle (tmux)

    func setupTmuxPanes() {
        guard let viewModel else { return }

        // Tear down any non-tmux single pane that was up first.
        if let single = singlePaneVC {
            single.willMove(toParent: nil)
            single.view.removeFromSuperview()
            single.removeFromParent()
            singlePaneVC = nil
        }

        for paneVM in viewModel.paneViewModels {
            addPaneController(for: paneVM)
        }
        updatePaneVisibility()
        layoutSurface(animated: false)
        floatingToolbar.isHidden = paneControllers.isEmpty
    }

    func refreshPanes() {
        guard let viewModel else { return }
        let currentIDs = Set(paneControllers.keys)
        let newIDs = Set(viewModel.paneViewModels.map(\.paneID))

        for id in currentIDs.subtracting(newIDs) {
            if let vc = paneControllers.removeValue(forKey: id) {
                vc.willMove(toParent: nil)
                vc.view.removeFromSuperview()
                vc.removeFromParent()
            }
        }
        for paneVM in viewModel.paneViewModels where !currentIDs.contains(paneVM.paneID) {
            addPaneController(for: paneVM)
        }

        updatePaneVisibility()
        layoutSurface(animated: false)
        floatingToolbar.isHidden = paneControllers.isEmpty
    }

    private func addPaneController(for paneVM: PaneViewModel) {
        let paneID = paneVM.paneID
        let vc = makeContainerVC()
        vc.bindToPaneVM(paneVM)

        vc.onSelectPaneTapped = { [weak self] in
            self?.viewModel?.selectPane(paneID)
            self?.updatePaneVisibility()
        }
        vc.onSplitRequested = { [weak self] horizontal in
            self?.viewModel?.splitPane(horizontal: horizontal)
        }
        vc.onCloseRequested = { [weak self] in
            self?.viewModel?.closePane(paneID)
        }
        vc.onToggleZoom = { [weak self] in
            self?.viewModel?.toggleZoom(paneID)
        }
        vc.onSizeChanged = { [weak self] cols, rows in
            self?.handleSwiftTermSize(cols: cols, rows: rows, sourcePaneID: paneID)
        }

        addChild(vc)
        view.insertSubview(vc.view, belowSubview: floatingToolbar)
        vc.didMove(toParent: self)

        paneControllers[paneID] = vc
    }

    /// Forward SwiftTerm's authoritative cols×rows to tmux. All pane VCs share
    /// the same frame (only the active one is unhidden), so they all report the
    /// same size — we dedupe to one push per distinct (cols, rows).
    ///
    /// For multi-pane sessions tmux still divides the client window across
    /// panes per the current layout. Bento's UX (one visible pane at a time,
    /// fullscreen) wants the active pane to fill the client — handled by
    /// auto-zoom in `TerminalViewModel.selectPane` / `setupTmuxPanes`.
    private func handleSwiftTermSize(cols: Int, rows: Int, sourcePaneID: TmuxPaneID) {
        guard let viewModel else { return }
        let paneCount = viewModel.paneViewModels.count
        dlog("swifttterm sizeChanged: \(cols)x\(rows) pane=\(sourcePaneID) total=\(paneCount)")
        guard lastTmuxClientSize?.cols != cols || lastTmuxClientSize?.rows != rows else { return }
        lastTmuxClientSize = (cols, rows)
        viewModel.resizeTmuxClient(cols: cols, rows: rows)
    }

    private func makeContainerVC() -> TerminalContainerVC {
        let vc = TerminalContainerVC()
        vc.voiceController = voiceController
        return vc
    }

    /// Show only the active pane; hide all others. Title bar state-dot and
    /// active flag are pushed down too so the floating toolbar's anchor uses
    /// the pane's current frame.
    private func updatePaneVisibility() {
        guard let viewModel else { return }
        let activeID = viewModel.activePaneID
        for paneVM in viewModel.paneViewModels {
            guard let vc = paneControllers[paneVM.paneID] else { continue }
            let isActive = (paneVM.paneID == activeID)
            vc.view.isHidden = !isActive
            vc.updatePaneState(paneVM.paneState, active: isActive)
        }
        syncBackgroundToActivePane()
    }

    // MARK: - Layout

    /// Available content area = view bounds minus bottom safe area minus
    /// keyboard inset.
    private var availableContentRect: CGRect {
        let bottomSafe = view.safeAreaInsets.bottom
        let reserve = max(keyboardInsetBottom, bottomSafe)
        return CGRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: max(0, view.bounds.height - reserve)
        )
    }

    /// Reserved strip at the bottom of the available area for the floating
    /// quick-keys toolbar. The active pane is sized to sit ABOVE this strip so
    /// the toolbar always has somewhere to land without overlapping content.
    private var toolbarReserveHeight: CGFloat {
        floatingToolbar.isHidden ? 0
            : FloatingQuickKeysToolbar.toolbarHeight + 2 * FloatingQuickKeysToolbar.edgeGap
    }

    private func layoutSurface(animated: Bool) {
        let available = availableContentRect
        let reserve = toolbarReserveHeight
        let paneRect = CGRect(
            x: available.minX,
            y: available.minY,
            width: available.width,
            height: max(0, available.height - reserve)
        )

        // Active pane + all hidden siblings get the same frame; only the
        // active one is unhidden. This keeps all SwiftTerm buffers sized
        // consistently so a pane switch doesn't trigger an unexpected resize.
        if let single = singlePaneVC {
            single.view.frame = paneRect
        } else {
            for vc in paneControllers.values {
                vc.view.frame = paneRect
            }
        }

        // Floating toolbar positions itself relative to the active pane's
        // frame, but stays within the container's available area.
        if !floatingToolbar.isHidden {
            let containerBounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: available.maxY)
            floatingToolbar.updatePosition(paneFrame: paneRect,
                                           containerBounds: containerBounds,
                                           animated: animated)
        }

        // tmux client size is driven by SwiftTerm's `sizeChanged` callback
        // (see `handleSwiftTermSize`) — authoritative cell metrics, no
        // homemade math. We only reset the dedupe cache when leaving the
        // single-pane case so the next single-pane attach pushes its size
        // fresh.
        if singlePaneVC != nil || viewModel?.paneViewModels.count != 1 {
            lastTmuxClientSize = nil
        }
    }

    // MARK: - View events

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSurface(animated: false)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        layoutSurface(animated: false)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.layoutSurface(animated: false)
        })
    }
}
