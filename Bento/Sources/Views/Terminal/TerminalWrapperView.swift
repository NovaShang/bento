import SwiftUI
import SwiftTmux
import BentoTerminalCore

/// Top-level terminal view mode (PRD §2.4). Tiles = spatial 1:1 mirror of the
/// tmux window; List = flat pane picker. Both can drill into a single-pane
/// focus (tmux zoom).
enum TerminalDisplayMode: String, CaseIterable {
    case tiles
    case list

    var label: String { self == .tiles ? "Tiles" : "List" }

    /// PRD §2.4 default: phone → List, iPad → Tiles.
    static var deviceDefault: TerminalDisplayMode {
        UIDevice.current.userInterfaceIdiom == .pad ? .tiles : .list
    }
}

/// Sticky size state (PRD §2.5). Tracking = we own the size (= device); Pinned =
/// respect the window's native (foreign) size and never auto-resize. It's a
/// state, not a one-shot action: remembered per session.
enum TerminalSizingMode: String {
    case tracking
    case pinned

    /// Persisted choice for a session key, or nil if the user hasn't chosen yet
    /// (→ show the connect dialog).
    static func stored(for key: String) -> TerminalSizingMode? {
        guard let raw = UserDefaults.standard.string(forKey: "sizingMode.\(key)") else { return nil }
        return TerminalSizingMode(rawValue: raw)
    }
    static func store(_ mode: TerminalSizingMode, for key: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: "sizingMode.\(key)")
    }
}

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
    @State private var sizingMode: TerminalSizingMode = .tracking
    @State private var showSizingDialog = false
    @State private var sizingResolved = false
    @AppStorage("terminalDisplayMode") private var storedMode: String = TerminalDisplayMode.deviceDefault.rawValue

    private var displayMode: TerminalDisplayMode {
        TerminalDisplayMode(rawValue: storedMode) ?? .deviceDefault
    }

    private var host: Host { viewModel.host }

    /// Persistence key for the sizing choice (per host + tmux session).
    private var sessionKey: String {
        "\(host.id.uuidString).\(viewModel.activeTmuxSessionName ?? "default")"
    }

    /// Show the flat List picker only in list mode and when no pane is focused
    /// (zoomed). A zoomed pane always shows the surface fullscreen.
    private var showingList: Bool {
        displayMode == .list && viewModel.zoomedPaneID == nil && viewModel.isTmuxReady
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(true)
        .overlay { voiceOverlay }
        .overlay { onboardingOverlay }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Connection Error", isPresented: $viewModel.showError) {
            Button("Dismiss", role: .cancel) { dismiss() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        // PRD §2.5: the connect dialog is the first-time size-state choice
        // (not a one-shot adjust). Remembered per session.
        .confirmationDialog("Window size", isPresented: $showSizingDialog, titleVisibility: .visible) {
            Button("Fit to my device") { setSizing(.tracking) }
            Button("Keep original size") { setSizing(.pinned) }
        } message: {
            Text("This window may already be sized for another screen. Fit it to this device, or keep its original size and pan to navigate?")
        }
        .onChange(of: viewModel.isTmuxReady) { _, ready in
            if ready { resolveSizing() }
        }
        .onAppear { if viewModel.isTmuxReady { resolveSizing() } }
    }

    /// Resolve the sticky sizing state once tmux is ready: use the stored choice,
    /// or prompt (PRD §2.5). A single-pane window that already equals the device
    /// needs no prompt — default to Tracking silently.
    private func resolveSizing() {
        guard !sizingResolved, viewModel.isTmuxReady else { return }
        sizingResolved = true
        if let stored = TerminalSizingMode.stored(for: sessionKey) {
            sizingMode = stored
        } else if viewModel.paneViewModels.count <= 1 {
            sizingMode = .tracking
        } else {
            showSizingDialog = true
        }
    }

    private func setSizing(_ mode: TerminalSizingMode) {
        sizingMode = mode
        TerminalSizingMode.store(mode, for: sessionKey)
        if mode == .tracking { viewModel.resetTmuxClientToDeviceSize() }
    }

    @ViewBuilder
    private var content: some View {
        if showingList {
            PaneListView(viewModel: viewModel) { paneID in
                // Tap a row → focus that pane fullscreen, device-fit (PRD §2.4
                // "List focus 始终 Tracking"). Focus is tmux zoom.
                viewModel.selectPane(paneID)
                if viewModel.zoomedPaneID != paneID {
                    viewModel.toggleZoom(paneID)
                }
            }
        } else {
            SinglePaneSurface(
                viewModel: viewModel,
                voiceController: voiceController,
                displayMode: displayMode,
                sizingMode: sizingMode
            )
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var voiceOverlay: some View {
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

    @ViewBuilder
    private var onboardingOverlay: some View {
        if showOnboarding, case .connected = viewModel.connectionState {
            GestureOnboardingOverlay {
                GestureOnboardingOverlay.markDismissed()
                withAnimation { showOnboarding = false }
            }
            .transition(.opacity)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: backTapped) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Sessions").font(.body)
                }
            }

            Spacer(minLength: 4)

            VStack(spacing: 1) {
                // PRD §3.6: the session name is the primary title; the host is
                // the subtitle. Falls back to the host name before a tmux
                // session is attached (no-tmux / choosing phase).
                Text(viewModel.activeTmuxSessionName ?? host.displayName)
                    .font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    connectionDot
                    Text(host.displayName).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if viewModel.isTmuxReady {
                viewToggle
            }

            sessionMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Tiles | List segmented control (PRD §3.6 — a persistent top-bar control,
    /// not buried in a menu).
    private var viewToggle: some View {
        Picker("View", selection: Binding(
            get: { displayMode },
            set: { newMode in
                // Leaving a focused (zoomed) pane when switching to a browse
                // view feels right; unzoom so the chosen view is visible.
                if viewModel.zoomedPaneID != nil, let z = viewModel.zoomedPaneID {
                    viewModel.toggleZoom(z)
                }
                storedMode = newMode.rawValue
            }
        )) {
            ForEach(TerminalDisplayMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var sessionMenu: some View {
        Menu {
            if viewModel.isTmuxReady {
                Button(action: { viewModel.splitPane(horizontal: true) }) {
                    Label("Split Horizontal", systemImage: "rectangle.split.2x1")
                }
                Button(action: { viewModel.splitPane(horizontal: false) }) {
                    Label("Split Vertical", systemImage: "rectangle.split.1x2")
                }
                Divider()
                // PRD §2.5 sticky size state toggle (session scope).
                Button(action: { setSizing(sizingMode == .tracking ? .pinned : .tracking) }) {
                    if sizingMode == .tracking {
                        Label("Pin to Original Size", systemImage: "pin")
                    } else {
                        Label("Track My Device", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                Button(action: { setSizing(.tracking) }) {
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

    @ViewBuilder
    private var connectionDot: some View {
        switch viewModel.connectionState {
        case .connected: Circle().fill(.green).frame(width: 5, height: 5)
        case .connecting: ProgressView().scaleEffect(0.5)
        case .failed: Circle().fill(.red).frame(width: 5, height: 5)
        case .disconnected: Circle().fill(.secondary).frame(width: 5, height: 5)
        }
    }

    private func backTapped() {
        // If a pane is focused (zoomed), back exits focus first instead of
        // leaving the session — matches the drill-down mental model.
        if let z = viewModel.zoomedPaneID {
            viewModel.toggleZoom(z)
        } else {
            dismiss()
        }
    }
}

// MARK: - Single-pane / tiled surface bridge

/// SwiftUI bridge for the UIKit container that hosts the live terminal panes
/// (tiled, or one focused) plus the floating quick-keys toolbar.
struct SinglePaneSurface: UIViewControllerRepresentable {
    @ObservedObject var viewModel: TerminalViewModel
    @ObservedObject var voiceController: VoiceInputController
    var displayMode: TerminalDisplayMode
    var sizingMode: TerminalSizingMode

    /// Observe stateVersion so SwiftUI triggers updateUIViewController on state polls.
    var stateVersion: Int { viewModel.stateVersion }

    func makeUIViewController(context: Context) -> PaneContainerVC {
        let vc = PaneContainerVC()
        vc.viewModel = viewModel
        vc.voiceController = voiceController
        vc.displayMode = displayMode
        vc.sizingMode = sizingMode

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

    static func dismantleUIViewController(_ vc: PaneContainerVC, coordinator: ()) {
        // SwiftUI removed this representable (screen dismissed) — free the
        // ghostty surfaces NOW, before UIKit tears down the layer hierarchy.
        vc.teardownAll()
    }

    func updateUIViewController(_ vc: PaneContainerVC, context: Context) {
        vc.displayMode = displayMode
        vc.sizingMode = sizingMode
        if viewModel.isTmuxReady {
            if vc.singlePaneVC != nil {
                vc.setupTmuxPanes()
            } else {
                vc.refreshPanes()
            }
        }
    }
}

// MARK: - Pane Container

/// Hosts the live terminal panes. Two layouts (PRD §2.4):
///   - **Tiles**: every tmux pane shown at once, positioned 1:1 by its tmux cell
///     geometry. The container owns the tmux client size (one push for the whole
///     viewport) and sizes each surface to its exact pane cell grid so TUIs don't
///     tear. Tap = select-pane; ⛶ = zoom.
///   - **Focus**: a single pane (tmux `window_zoomed_flag`) fills the viewport.
///     Its surface drives the tmux client size (device-fit).
/// Non-tmux sessions are a single pane (focus layout).
final class PaneContainerVC: UIViewController {
    var viewModel: TerminalViewModel?
    var voiceController: VoiceInputController?
    var displayMode: TerminalDisplayMode = .tiles {
        didSet { if oldValue != displayMode { view.setNeedsLayout() } }
    }

    /// Tmux-mode pane controllers, one per pane.
    private(set) var paneControllers: [TmuxPaneID: TerminalContainerVC] = [:]
    /// Non-tmux single pane controller, bound directly to TerminalViewModel.
    private(set) var singlePaneVC: TerminalContainerVC?

    private let floatingToolbar = FloatingQuickKeysToolbar()
    private var keyboardInsetBottom: CGFloat = 0

    var sizingMode: TerminalSizingMode = .tracking {
        didSet { if oldValue != sizingMode { view.setNeedsLayout() } }
    }

    /// Holds the pane VCs. When the page (tmux size) is larger than the viewport
    /// (PRD §2.2, Pinned), this view is bigger than the screen and two-finger pan
    /// translates it. When page ≤ viewport it sits top-left, no scroll.
    private let contentView = UIView()
    /// Pan offset of the content view (≤ 0 on each axis), in points.
    private var contentOffset: CGPoint = .zero

    /// Font cell size in device pixels, learned from the first surface that
    /// reports it; constant for the font.
    private var cellPx: CGSize?
    /// Last cols×rows pushed to tmux (dedupe).
    private var lastClient: (cols: Int, rows: Int)?
    private var clientResizeWork: DispatchWorkItem?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term.bg
        contentView.clipsToBounds = false
        view.addSubview(contentView)
        setupFloatingToolbar()
        setupKeyboardObservers()
        setupPanGesture()
        NotificationCenter.default.addObserver(
            self, selector: #selector(activePaneAppearanceChanged),
            name: .terminalThemeChanged, object: nil)
    }

    /// Two-finger pan navigates the page when it's larger than the viewport
    /// (PRD §3.1, low priority — never steals the single-finger scrollback or
    /// long-press voice gestures).
    private func setupPanGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePagePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)
    }

    private var panStartOffset: CGPoint = .zero

    @objc private func handlePagePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            panStartOffset = contentOffset
        case .changed:
            let t = g.translation(in: view)
            contentOffset = CGPoint(x: panStartOffset.x + t.x, y: panStartOffset.y + t.y)
            applyContentFrame()
        default:
            applyContentFrame()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Tear down every pane's ghostty surface on the main thread before this
    /// container/view is released (e.g. the screen is dismissed). Called from
    /// SinglePaneSurface.dismantleUIViewController so it happens BEFORE the
    /// layer hierarchy is torn down — otherwise the display link draws into a
    /// half-freed Metal layer and crashes.
    func teardownAll() {
        singlePaneVC?.teardown()
        for vc in paneControllers.values { vc.teardown() }
    }

    private func setupFloatingToolbar() {
        floatingToolbar.onKeyTap = { [weak self] key in
            self?.focusedOrActiveVC?.handleAccessoryKey(key)
        }
        floatingToolbar.isHidden = true
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
        // Keyboard changes the VIEWPORT only — it never changes the page (tmux
        // size). So we only reposition the floating toolbar; pane frames and the
        // tmux client size are computed from a keyboard-independent page rect.
        UIView.animate(withDuration: duration, delay: 0, options: opts) {
            self.positionFloatingToolbar()
            self.view.layoutIfNeeded()
        }
    }

    @objc private func activePaneAppearanceChanged() {
        DispatchQueue.main.async { [weak self] in self?.syncBackgroundToActivePane() }
    }

    private func syncBackgroundToActivePane() {
        let bg = focusedOrActiveVC?.view.backgroundColor ?? STTheme.term.bg
        guard view.backgroundColor != bg else { return }
        UIView.animate(withDuration: 0.26) { self.view.backgroundColor = bg }
    }

    // MARK: - Focus / active resolution

    /// The pane currently zoomed (focused), if any and present.
    private var focusedPaneVC: TerminalContainerVC? {
        guard let id = viewModel?.zoomedPaneID else { return nil }
        return paneControllers[id]
    }

    /// The VC the floating toolbar / keyboard target: focused pane, else active.
    private var focusedOrActiveVC: TerminalContainerVC? {
        if let s = singlePaneVC { return s }
        if let f = focusedPaneVC { return f }
        if let id = viewModel?.activePaneID, let vc = paneControllers[id] { return vc }
        return paneControllers.values.first
    }

    // MARK: - Non-tmux single pane

    func setupSinglePane() {
        guard let viewModel else { return }
        let vc = makeContainerVC()
        vc.bindToTerminalVM(viewModel)
        vc.titleBar.isActivePane = true
        vc.titleBar.menuButton.isHidden = true
        vc.titleBar.maximizeButton.isHidden = true
        addChild(vc)
        contentView.addSubview(vc.view)
        vc.didMove(toParent: self)
        singlePaneVC = vc
        floatingToolbar.isHidden = false
        view.setNeedsLayout()
        syncBackgroundToActivePane()
    }

    // MARK: - Tmux panes

    func setupTmuxPanes() {
        guard let viewModel else { return }
        if let single = singlePaneVC {
            single.teardown()
            single.willMove(toParent: nil)
            single.view.removeFromSuperview()
            single.removeFromParent()
            singlePaneVC = nil
        }
        for paneVM in viewModel.paneViewModels {
            if paneControllers[paneVM.paneID] == nil { addPaneController(for: paneVM) }
        }
        floatingToolbar.isHidden = paneControllers.isEmpty
        view.setNeedsLayout()
    }

    func refreshPanes() {
        guard let viewModel else { return }
        let currentIDs = Set(paneControllers.keys)
        let newIDs = Set(viewModel.paneViewModels.map(\.paneID))
        for id in currentIDs.subtracting(newIDs) {
            if let vc = paneControllers.removeValue(forKey: id) {
                vc.teardown()
                vc.willMove(toParent: nil)
                vc.view.removeFromSuperview()
                vc.removeFromParent()
            }
        }
        for paneVM in viewModel.paneViewModels where !currentIDs.contains(paneVM.paneID) {
            addPaneController(for: paneVM)
        }
        floatingToolbar.isHidden = paneControllers.isEmpty
        view.setNeedsLayout()
    }

    private func addPaneController(for paneVM: PaneViewModel) {
        let paneID = paneVM.paneID
        let vc = makeContainerVC()
        vc.bindToPaneVM(paneVM)
        vc.onSelectPaneTapped = { [weak self] in
            self?.viewModel?.selectPane(paneID)
            self?.view.setNeedsLayout()
        }
        vc.onSplitRequested = { [weak self] horizontal in
            self?.viewModel?.selectPane(paneID)
            self?.viewModel?.splitPane(horizontal: horizontal)
        }
        vc.onCloseRequested = { [weak self] in self?.viewModel?.closePane(paneID) }
        vc.onToggleZoom = { [weak self] in self?.viewModel?.toggleZoom(paneID) }
        vc.onRename = { [weak self] title in self?.viewModel?.renamePane(paneID, to: title) }
        vc.onSetProfile = { [weak self] id in self?.viewModel?.setPaneProfile(id, for: paneID) }
        vc.currentProfileID = { [weak self] in self?.viewModel?.paneProfile(for: paneID) }
        vc.onSizeChanged = { [weak self] size in
            self?.handlePaneSize(size, paneID: paneID)
        }
        addChild(vc)
        contentView.addSubview(vc.view)
        vc.didMove(toParent: self)
        paneControllers[paneID] = vc
    }

    private func makeContainerVC() -> TerminalContainerVC {
        let vc = TerminalContainerVC()
        vc.voiceController = voiceController
        return vc
    }

    /// Learn the cell pixel size from any surface; drive the tmux client size
    /// from the focused/single pane (which fills the page). Tiled panes are
    /// fixed-size and never push.
    private func handlePaneSize(_ size: TerminalSurfaceSize, paneID: TmuxPaneID) {
        if cellPx == nil, size.cellWidthPx > 0, size.cellHeightPx > 0 {
            cellPx = CGSize(width: size.cellWidthPx, height: size.cellHeightPx)
            view.setNeedsLayout()
        }
        // In focus mode, the visible pane fills the page → its reported size is
        // the device-fit client size. Push it (deduped).
        guard isFocusLayout, paneID == effectiveFocusID else { return }
        pushClientSize(cols: size.columns, rows: size.rows)
    }

    private func pushClientSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        // PRD §2.6 resize whitelist: only Tracking lets the client own the tmux
        // geometry. Pinned respects the window's native size — never push.
        guard sizingMode == .tracking else { return }
        guard lastClient?.cols != cols || lastClient?.rows != rows else { return }
        lastClient = (cols, rows)
        clientResizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.viewModel?.resizeTmuxClient(cols: cols, rows: rows)
        }
        clientResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    // MARK: - Layout

    /// Whether we're showing a single full pane (zoomed focus or non-tmux).
    private var isFocusLayout: Bool {
        singlePaneVC != nil || viewModel?.zoomedPaneID != nil
            || (viewModel?.paneViewModels.count ?? 0) <= 1
    }

    private var effectiveFocusID: TmuxPaneID? {
        if let z = viewModel?.zoomedPaneID { return z }
        if (viewModel?.paneViewModels.count ?? 0) == 1 { return viewModel?.paneViewModels.first?.paneID }
        return viewModel?.activePaneID
    }

    /// Page rect = the area the tmux page maps to. KEYBOARD-INDEPENDENT (PRD
    /// §2.6): only the bottom safe area is reserved, never the keyboard, so the
    /// keyboard popping up never resizes tmux.
    private var pageRect: CGRect {
        let bottom = view.safeAreaInsets.bottom
        return CGRect(x: 0, y: 0, width: view.bounds.width,
                      height: max(0, view.bounds.height - bottom))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
        positionFloatingToolbar()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout() })
    }

    private var displayScale: CGFloat { view.window?.screen.scale ?? UIScreen.main.scale }

    /// Points per tmux cell, or nil until learned. ghostty reports the cell size
    /// in device pixels, so divide by the screen scale to get points.
    private var pointsPerCell: CGSize? {
        cellPx.map { CGSize(width: $0.width / displayScale, height: $0.height / displayScale) }
    }

    private func layoutPanes() {
        if let single = singlePaneVC {
            let page = pageSizeForFocus(cols: nil)
            setContentFrame(page)
            single.tiled = false
            single.fixedTerminalCellSize = nil
            single.view.frame = CGRect(origin: .zero, size: page)
            return
        }
        guard let viewModel, !paneControllers.isEmpty else { return }

        if isFocusLayout, let focusID = effectiveFocusID {
            layoutFocus(focusID)
        } else {
            layoutTiles(viewModel.paneViewModels)
        }
        syncBackgroundToActivePane()
    }

    /// Single pane fills the page; the rest are hidden. In Tracking the page is
    /// the viewport (device-fit, drives tmux); in Pinned the page is the pane's
    /// natural cell size (may exceed the viewport → two-finger pan).
    private func layoutFocus(_ focusID: TmuxPaneID) {
        let pane = viewModel?.paneViewModels.first(where: { $0.paneID == focusID })?.pane
        let page = pageSizeForFocus(cols: pane.map { ($0.width, $0.height) })
        setContentFrame(page)
        for (id, vc) in paneControllers {
            let isFocus = (id == focusID)
            vc.view.isHidden = !isFocus
            if isFocus {
                vc.tiled = false
                vc.fixedTerminalCellSize = nil
                vc.view.frame = CGRect(origin: .zero, size: page)
                vc.titleBar.isActivePane = true
                vc.titleBar.isMaximized = (viewModel?.zoomedPaneID == focusID)
                if let pvm = viewModel?.paneViewModels.first(where: { $0.paneID == focusID }) {
                    vc.updatePaneState(pvm.paneState, active: true)
                }
            }
        }
    }

    /// Tile all panes by tmux cell geometry inside the content view. In Tracking
    /// the page == viewport (proportional fit, container pushes one client size);
    /// in Pinned the page is the window's natural cell size (pannable, no push).
    private func layoutTiles(_ panes: [PaneViewModel]) {
        let totalCols = CGFloat(max(panes.map { $0.pane.x + $0.pane.width }.max() ?? 1, 1))
        let totalRows = CGFloat(max(panes.map { $0.pane.y + $0.pane.height }.max() ?? 1, 1))
        let levels = max(Set(panes.map { $0.pane.y }).count, 1)
        let page = pageSizeForTiles(totalCols: totalCols, totalRows: totalRows, levels: levels)
        setContentFrame(page)

        let activeID = viewModel?.activePaneID
        let ppc = pointsPerCell

        for (id, vc) in paneControllers {
            guard let pvm = panes.first(where: { $0.paneID == id }) else { continue }
            let p = pvm.pane
            vc.view.isHidden = false
            vc.tiled = true
            vc.view.frame = CGRect(
                x: (CGFloat(p.x) / totalCols) * page.width,
                y: (CGFloat(p.y) / totalRows) * page.height,
                width: (CGFloat(p.width) / totalCols) * page.width,
                height: (CGFloat(p.height) / totalRows) * page.height
            )
            // Cell-exact surface (one cell larger so ghostty's grid >= tmux —
            // mirrors the macOS host; the overflow is clipped).
            vc.fixedTerminalCellSize = ppc.map {
                CGSize(width: CGFloat(p.width + 1) * $0.width,
                       height: CGFloat(p.height + 1) * $0.height)
            }
            vc.titleBar.isMaximized = false
            vc.updatePaneState(pvm.paneState, active: id == activeID)
        }
        if sizingMode == .tracking {
            recomputeTilesClientSize(totalRows: totalRows, levels: levels)
        }
    }

    // MARK: - Page sizing & content offset

    private var titleBarH: CGFloat { TerminalContainerVC.titleBarHeightValue }

    /// Page size for a focused/single pane. Tracking → viewport; Pinned → the
    /// pane's natural cell size (+ title bar), which may exceed the viewport.
    private func pageSizeForFocus(cols: (Int, Int)?) -> CGSize {
        let rect = pageRect
        guard sizingMode == .pinned, let ppc = pointsPerCell, let (c, r) = cols else {
            return rect.size
        }
        return CGSize(width: CGFloat(c) * ppc.width,
                      height: CGFloat(r) * ppc.height + titleBarH)
    }

    /// Page size for Tiles. Tracking → viewport; Pinned → natural window size.
    private func pageSizeForTiles(totalCols: CGFloat, totalRows: CGFloat, levels: Int) -> CGSize {
        let rect = pageRect
        guard sizingMode == .pinned, let ppc = pointsPerCell else { return rect.size }
        return CGSize(width: totalCols * ppc.width,
                      height: totalRows * ppc.height + CGFloat(levels) * titleBarH)
    }

    /// Place the content view at the clamped pan offset. Page ≤ viewport → pinned
    /// top-left, no scroll (PRD §2.2); page > viewport → pannable.
    private func setContentFrame(_ page: CGSize) {
        let rect = pageRect
        let minX = min(0, rect.width - page.width)
        let minY = min(0, rect.height - page.height)
        let clampedX = max(minX, min(0, contentOffset.x))
        let clampedY = max(minY, min(0, contentOffset.y))
        contentOffset = CGPoint(x: clampedX, y: clampedY)
        contentView.frame = CGRect(x: rect.minX + clampedX, y: rect.minY + clampedY,
                                   width: page.width, height: page.height)
    }

    private func applyContentFrame() {
        // Re-clamp using the current content size after a pan.
        setContentFrame(contentView.bounds.size)
        positionFloatingToolbar()
    }

    /// One tmux client size for the whole viewport (Tiles, Tracking only).
    private func recomputeTilesClientSize(totalRows: CGFloat, levels: Int) {
        guard let cellPx else { return }
        let rect = pageRect
        guard rect.width > 0, rect.height > 0 else { return }
        let scale = displayScale
        let usableH = rect.height - CGFloat(levels) * titleBarH
        let cols = max(Int((rect.width * scale) / cellPx.width), 2)
        let rows = max(Int((usableH * scale) / cellPx.height), 1)
        pushClientSize(cols: cols, rows: rows)
    }

    /// Position the floating toolbar above the keyboard / focused pane. The pane
    /// frames live in the (possibly panned) content view, so offset into view
    /// coordinates.
    private func positionFloatingToolbar() {
        guard !floatingToolbar.isHidden else { return }
        let paneFrame = focusedOrActiveVC?.view.frame ?? .zero
        let origin = contentView.frame.origin
        let anchor = CGRect(x: paneFrame.minX + origin.x, y: paneFrame.minY + origin.y,
                            width: paneFrame.width, height: paneFrame.height)
        let bottomSafe = view.safeAreaInsets.bottom
        let reserve = max(keyboardInsetBottom, bottomSafe)
        let containerBounds = CGRect(x: 0, y: 0, width: view.bounds.width,
                                     height: max(0, view.bounds.height - reserve))
        floatingToolbar.updatePosition(paneFrame: anchor, containerBounds: containerBounds, animated: false)
    }
}

// MARK: - Pane List (flat view)

/// Flat List view (PRD §2.4): a pane picker for phones. Each row shows a state
/// dot (Working/Idle/Awaiting), the pane's command/title, and its size. Tapping
/// a row drills into that pane's fullscreen focus. No thumbnails (PRD MVP).
struct PaneListView: View {
    @ObservedObject var viewModel: TerminalViewModel
    var onSelect: (TmuxPaneID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.paneViewModels) { paneVM in
                    PaneRow(paneVM: paneVM,
                            isActive: paneVM.paneID == viewModel.activePaneID)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(paneVM.paneID) }
                }
            }
            .padding(16)
        }
        .id(viewModel.stateVersion)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bentoShell)
    }
}

private struct PaneRow: View {
    @ObservedObject var paneVM: PaneViewModel
    var isActive: Bool

    private var title: String {
        let cmd = paneVM.pane.currentCommand?.trimmingCharacters(in: .whitespaces) ?? ""
        let t = paneVM.pane.title?.trimmingCharacters(in: .whitespaces) ?? ""
        if !t.isEmpty, t != cmd { return cmd.isEmpty ? t : "\(cmd) · \(t)" }
        return cmd.isEmpty ? "shell" : cmd
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(STTheme.dotColor(for: paneVM.paneState)))
                .frame(width: 10, height: 10)
                .shadow(color: glowColor, radius: glowRadius)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.bentoInk)
                    .lineLimit(1)
                Text("\(paneVM.pane.width)×\(paneVM.pane.height)\(stateSuffix)")
                    .font(.caption2)
                    .foregroundStyle(Color.bentoInkDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.bentoInkDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.bentoSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? Color.bentoEmerald : Color.bentoBorder,
                              lineWidth: isActive ? 1.5 : 1)
        )
    }

    private var stateSuffix: String {
        switch paneVM.paneState {
        case .awaitingInput: return " · awaiting"
        case .working: return " · working"
        case .idle: return ""
        }
    }

    private var glowColor: Color {
        switch paneVM.paneState {
        case .awaitingInput: return Color(STTheme.dotColor(for: paneVM.paneState)).opacity(0.8)
        case .working: return Color(STTheme.dotColor(for: paneVM.paneState)).opacity(0.6)
        case .idle: return .clear
        }
    }

    private var glowRadius: CGFloat {
        switch paneVM.paneState {
        case .awaitingInput: return 3
        case .working: return 2.5
        case .idle: return 0
        }
    }
}
