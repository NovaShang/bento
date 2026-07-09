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
        .overlay(alignment: .top) { reconnectingBanner }
        .overlay { voiceOverlay }
        .overlay { onboardingOverlay }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $voiceController.showPreview) {
            VoicePreviewSheet(controller: voiceController)
        }
        .alert("Connection Error", isPresented: $viewModel.showError) {
            Button("Retry") { viewModel.retry() }
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
            if ready {
                resolveSizing()
                // Populate the session switcher (PRD §3.6) once attached.
                Task { await viewModel.refreshTmuxSessions() }
            }
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

    /// Top pill shown while an auto-reconnect loop is in flight, so the session
    /// never looks silently frozen after a drop / lock-screen suspend.
    @ViewBuilder
    private var reconnectingBanner: some View {
        if viewModel.isReconnecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Color.bentoEmerald)
                Text("Reconnecting…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.bentoInkDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.bentoSurface))
            .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1))
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: viewModel.isReconnecting)
        }
    }

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

            sessionTitle

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

    /// Session name (primary) + host (subtitle). PRD §3.6: tapping the name is a
    /// quick session switcher — a menu of the host's tmux sessions, switch in
    /// place. Plain (non-tappable) text before tmux is attached.
    @ViewBuilder
    private var sessionTitle: some View {
        let label = VStack(spacing: 1) {
            Text(viewModel.activeTmuxSessionName ?? host.displayName)
                .font(.headline).lineLimit(1)
            HStack(spacing: 4) {
                connectionDot
                Text(host.displayName).lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if viewModel.isTmuxReady {
            Menu {
                ForEach(viewModel.availableTmuxSessions, id: \.self) { name in
                    Button { viewModel.switchSession(name) } label: {
                        if name == viewModel.activeTmuxSessionName {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Divider()
                Button { Task { await viewModel.refreshTmuxSessions() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        } else {
            label
        }
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
                // One-shot "claim the session at MY size" + the PRD §2.5 sticky
                // sizing-mode toggle, under a labeled section so the resize
                // action is findable (it used to hide as "Fit Tmux to Device").
                Section("Session Size") {
                    Button(action: { setSizing(.tracking) }) {
                        Label("Fit to This Device", systemImage: "arrow.down.right.and.arrow.up.left.rectangle")
                    }
                    Button(action: { setSizing(sizingMode == .tracking ? .pinned : .tracking) }) {
                        if sizingMode == .tracking {
                            Label("Pin to Original Size", systemImage: "pin")
                        } else {
                            Label("Track My Device", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
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
    var viewModel: TerminalViewModel? {
        didSet { wireGeometryHook() }
    }
    var voiceController: VoiceInputController?

    /// Re-tile SYNCHRONOUSLY when `%layout-change` applies new pane geometry, so
    /// tiled surfaces resize to the new tmux size BEFORE the program's repaint
    /// output is fed to ghostty (same fix as the macOS host). In Tiles mode each
    /// surface is sized from tmux cell geometry; without this the relayout only
    /// happened on the debounced `refreshPanes` (~300ms later), so a TUI repainted
    /// at the new width into a still-old-size grid and stayed garbled until the
    /// next resize. `layoutIfNeeded` forces `layoutPanes()` now, on this same
    /// main-actor notification turn. (Focus mode is device-fit, so this is a
    /// harmless no-op there.)
    private func wireGeometryHook() {
        viewModel?.onGeometryApplied = { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }
    var displayMode: TerminalDisplayMode = .tiles {
        didSet { if oldValue != displayMode { view.setNeedsLayout() } }
    }

    /// Tmux-mode pane controllers, one per pane.
    private(set) var paneControllers: [TmuxPaneID: TerminalContainerVC] = [:]
    /// Non-tmux single pane controller, bound directly to TerminalViewModel.
    private(set) var singlePaneVC: TerminalContainerVC?

    private let floatingToolbar = FloatingQuickKeysToolbar()
    private var keyboardInsetBottom: CGFloat = 0

    /// The slice of the page hidden behind the keyboard — i.e. how far the
    /// keyboard reaches up into the page. `pageRect` now runs to the very bottom
    /// edge (no reserved bottom inset), so that's the full keyboard height. The
    /// keyboard shrinks the VIEWPORT, never the page (PRD §2.2/§2.6), so this
    /// drives content panning only, never tmux.
    private var keyboardOverlap: CGFloat {
        max(0, keyboardInsetBottom)
    }

    var sizingMode: TerminalSizingMode = .tracking {
        didSet { if oldValue != sizingMode { view.setNeedsLayout() } }
    }

    /// Holds the pane VCs. When the page (tmux size) is larger than the viewport
    /// (PRD §2.2, Pinned), this view is bigger than the screen and two-finger pan
    /// translates it. When page ≤ viewport it sits top-left, no scroll.
    private let contentView = UIView()
    /// Pan offset of the content view (≤ 0 on each axis), in points.
    private var contentOffset: CGPoint = .zero

    /// Transparent overlay over the panes that claims touches only on a divider
    /// between adjacent panes, to drag-resize them (tmux resize-pane). Mirrors
    /// the macOS `DividerOverlay`. Lives inside `contentView` so it pans with the
    /// page; kept on top of the pane views after each tile layout.
    private let dividerOverlay = TileDividerOverlay()

    /// Font cell size in device pixels, learned from the first surface that
    /// reports it; constant for the font.
    private var cellPx: CGSize?
    /// Last cols×rows pushed to tmux (dedupe).
    private var lastClient: (cols: Int, rows: Int)?
    private var clientResizeWork: DispatchWorkItem?

    // MARK: - Lifecycle

    /// The terminal runs to the bottom edge (see `pageRect`), so let the home
    /// indicator auto-dim — the UIKit way, which (unlike SwiftUI's
    /// `.persistentSystemOverlays(.hidden)`) doesn't interfere with the software
    /// keyboard's input handling.
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term.bg
        contentView.clipsToBounds = false
        view.addSubview(contentView)
        contentView.addSubview(dividerOverlay)
        dividerOverlay.onResize = { [weak self] paneID, vertical, deltaCells in
            self?.resizeBoundary(paneID: paneID, vertical: vertical, deltaCells: deltaCells)
        }
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
        // size) or the tmux client size (both come from the keyboard-independent
        // page rect, so the keyboard never resizes tmux). We respond by panning
        // the content up so the active pane's input stays above the keyboard,
        // re-clamping the offset, and repositioning the floating toolbar. On
        // hide, keyboardOverlap is 0 so the re-clamp pulls the page back.
        UIView.animate(withDuration: duration, delay: 0, options: opts) {
            self.revealActivePaneAboveKeyboard()
            self.applyContentFrame()
            self.view.layoutIfNeeded()
        }
    }

    /// Breathing room between the cursor and the keyboard's top edge.
    private static let cursorKeyboardMargin: CGFloat = 10

    /// Pan the content up just enough to lift the active pane's INSERTION POINT
    /// (the real terminal cursor) above the keyboard. The cursor isn't always at
    /// the pane bottom — TUIs (vim, forms, less) put it anywhere — so anchoring
    /// on the pane bottom hid the caret. Falls back to the pane bottom when the
    /// cursor rect isn't readable. No-op when nothing is hidden.
    private func revealActivePaneAboveKeyboard() {
        guard keyboardOverlap > 0, let vc = focusedOrActiveVC else { return }
        let keyboardTopInView = view.bounds.height - keyboardInsetBottom
        let anchorBottomInView: CGFloat
        if let caret = vc.cursorRect(in: view) {
            anchorBottomInView = caret.maxY + Self.cursorKeyboardMargin
        } else {
            anchorBottomInView = contentView.frame.minY + vc.view.frame.maxY
        }
        let overflow = anchorBottomInView - keyboardTopInView
        guard overflow > 0 else { return }
        contentOffset.y -= overflow
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
        vc.pathPreviewContext = { [weak self, weak vc] in
            self?.makePathPreviewContext(paneVM: nil, vc: vc)
        }
        vc.titleBar.isActivePane = true
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
        vc.pathPreviewContext = { [weak self, weak vc, weak paneVM] in
            self?.makePathPreviewContext(paneVM: paneVM, vc: vc)
        }
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
        vc.onTitleDrag = { [weak self] phase in
            self?.handleTitleSwap(source: paneID, phase: phase)
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

    /// Path preview: build the fetch context at tap time — the transport can
    /// reconnect and swap its underlying client, so nothing is cached here.
    /// cwd = the pane's live tmux path, falling back to the surface's OSC 7
    /// report (non-tmux sessions).
    private func makePathPreviewContext(paneVM: PaneViewModel?,
                                        vc: TerminalContainerVC?) -> PathPreviewContext? {
        guard let viewModel,
              let ssh = viewModel.activeTransport as? SSHService,
              let source = ssh.filePreviewSource() else { return nil }
        return PathPreviewContext(
            source: source,
            cwd: { [weak paneVM, weak vc] in
                if let path = await paneVM?.currentWorkingDirectory() { return path }
                return vc?.surface?.reportedPwd
            },
            hostLabel: viewModel.host.displayName,
            isLocal: false)
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
    /// §2.6): the keyboard never resizes tmux.
    private var pageRect: CGRect {
        // Respect the LEFT/RIGHT safe-area insets: in landscape on a notched
        // device they're non-zero, and without subtracting them ghostty counts
        // columns under the notch/home-indicator that aren't usable (the PTY
        // ends up a few columns too wide and TUIs wrap/misalign).
        //
        // The BOTTOM inset is deliberately NOT reserved: the terminal extends to
        // the very bottom edge (under the home indicator) so it reclaims that
        // strip as another usable row instead of an empty band. The home
        // indicator auto-dims (`.persistentSystemOverlays(.hidden)`), and the
        // floating toolbar still keeps clear of it (see `positionFloatingToolbar`).
        let insets = view.safeAreaInsets
        return CGRect(x: insets.left, y: 0,
                      width: max(0, view.bounds.width - insets.left - insets.right),
                      height: view.bounds.height)
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
        // No draggable dividers unless we lay out cell-exact tiles below.
        dividerOverlay.dividers = []
        if let single = singlePaneVC {
            let page = pageSizeForFocus(cols: nil)
            setContentFrame(page)
            single.tiled = false
            single.fixedTerminalCellSize = nil
            single.titleBarHeight = TerminalContainerVC.defaultTitleBarHeight
            single.surfaceInsetX = 0
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
                vc.titleBarHeight = TerminalContainerVC.defaultTitleBarHeight
                vc.surfaceInsetX = 0
                vc.view.frame = CGRect(origin: .zero, size: page)
                vc.titleBar.isActivePane = true
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
        let activeID = viewModel?.activePaneID

        guard let ppc = pointsPerCell else {
            // Cell size not learned yet: proportional bootstrap so the surfaces
            // lay out and report their metrics (which teaches cellPx). The next
            // layout pass re-runs cell-exact once a surface has reported.
            let page = pageRect.size
            setContentFrame(page)
            for (id, vc) in paneControllers {
                guard let pvm = panes.first(where: { $0.paneID == id }) else { continue }
                let p = pvm.pane
                vc.view.isHidden = false
                vc.tiled = true
                vc.titleBarHeight = TerminalContainerVC.defaultTitleBarHeight
                vc.surfaceInsetX = 0
                vc.fixedTerminalCellSize = nil
                vc.view.frame = CGRect(
                    x: (CGFloat(p.x) / totalCols) * page.width,
                    y: (CGFloat(p.y) / totalRows) * page.height,
                    width: (CGFloat(p.width) / totalCols) * page.width,
                    height: (CGFloat(p.height) / totalRows) * page.height)
                vc.updatePaneState(pvm.paneState, active: id == activeID)
            }
            return
        }

        // Cell-exact: map tmux cell geometry 1:1 to points, exactly as the macOS
        // host does. Each pane = a title bar (one cell tall, occupying tmux's
        // divider row) + a surface of exactly its cols×rows. The title bar height
        // equals one cell so stacked panes reuse divider rows and irregular
        // splits stay aligned (only the top bar adds height). Side-by-side panes
        // share the divider column: the container grows half a cell into it on
        // each side so neighbours meet, while surfaceInsetX keeps the surface at
        // its true cell size and position (ghostty's grid still == tmux's).
        let page = pageSizeForTiles(totalCols: totalCols, totalRows: totalRows)
        setContentFrame(page)
        let titleBar = ppc.height
        let halfGap = ppc.width / 2

        for (id, vc) in paneControllers {
            guard let pvm = panes.first(where: { $0.paneID == id }) else { continue }
            let p = pvm.pane
            vc.view.isHidden = false
            vc.tiled = true
            vc.titleBarHeight = titleBar
            vc.surfaceInsetX = halfGap
            vc.view.frame = CGRect(
                x: CGFloat(p.x) * ppc.width - halfGap,
                y: CGFloat(p.y) * ppc.height,
                width: CGFloat(p.width) * ppc.width + 2 * halfGap,
                height: titleBar + CGFloat(p.height) * ppc.height)
            // One cell larger than the pane so ghostty's grid >= tmux (point
            // rounding never drops a column/row); the overflow is clipped.
            vc.fixedTerminalCellSize = CGSize(width: CGFloat(p.width + 1) * ppc.width,
                                              height: CGFloat(p.height + 1) * ppc.height)
            vc.updatePaneState(pvm.paneState, active: id == activeID)
        }
        if sizingMode == .tracking {
            recomputeTilesClientSize()
        }
        // Refresh the drag-to-resize divider hot zones for the new geometry.
        dividerOverlay.frame = CGRect(origin: .zero, size: page)
        dividerOverlay.pointsPerCell = CGPoint(x: ppc.width, y: ppc.height)
        dividerOverlay.dividers = computeTileDividers(page: page, ppc: ppc)
        contentView.bringSubviewToFront(dividerOverlay)
    }

    // MARK: - Drag to resize (divider) & swap (title bar)

    /// Resize the boundary owned by `paneID` by a signed cell delta (tmux
    /// `resize-pane`). Vertical divider → grow Right/shrink Left; horizontal →
    /// Down/Up. Identical mapping to the macOS host's `resizeBoundary`.
    private func resizeBoundary(paneID: TmuxPaneID, vertical: Bool, deltaCells: Int) {
        guard deltaCells != 0 else { return }
        let dir = vertical ? (deltaCells > 0 ? "R" : "L")
                           : (deltaCells > 0 ? "D" : "U")
        viewModel?.resizePaneBy(paneID, direction: dir, amount: abs(deltaCells))
    }

    /// Compute divider hot zones from the current pane container frames, matching
    /// the macOS `computeDividers`. Side-by-side panes meet on the divider
    /// centerline (each container grew half a cell into the gap), so neighbours
    /// are detected within ~1 cell. The vertical hot zone is centred on the line;
    /// the horizontal one sits just ABOVE it (in the upper pane's surface) so it
    /// never covers the lower pane's title bar — which keeps title-bar drag-to-
    /// swap fully grabbable.
    private func computeTileDividers(page: CGSize, ppc: CGSize) -> [TileDividerOverlay.Divider] {
        let frames: [(id: TmuxPaneID, frame: CGRect)] = paneControllers.compactMap { id, vc in
            vc.view.isHidden ? nil : (id, vc.view.frame)
        }
        guard frames.count > 1 else { return [] }
        let gapTolX = max(ppc.width * 1.8, 6)
        let gapTolY = max(ppc.height * 1.8, 6)
        let eps: CGFloat = 2
        let hotV = TileDividerOverlay.hotThicknessV
        let above = TileDividerOverlay.hotAboveLine
        let below = TileDividerOverlay.hotBelowLine
        var result: [TileDividerOverlay.Divider] = []

        for a in frames {
            // Vertical divider: a pane sits just to the right of a's right edge.
            let rightEdge = a.frame.maxX
            if rightEdge < page.width - eps {
                let neighbors = frames.filter {
                    $0.frame.minX > rightEdge - eps
                        && $0.frame.minX - rightEdge < gapTolX
                        && yOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minX).min() {
                    let pos = (rightEdge + nearest) / 2
                    let yTop = neighbors.map { max($0.frame.minY, a.frame.minY) }.min() ?? a.frame.minY
                    let yBot = neighbors.map { min($0.frame.maxY, a.frame.maxY) }.max() ?? a.frame.maxY
                    result.append(.init(paneID: a.id, vertical: true, position: pos,
                                        hotRect: CGRect(x: pos - hotV / 2, y: yTop,
                                                        width: hotV, height: yBot - yTop)))
                }
            }
            // Horizontal divider: a pane sits just below a's bottom edge.
            let bottomEdge = a.frame.maxY
            if bottomEdge < page.height - eps {
                let neighbors = frames.filter {
                    $0.frame.minY > bottomEdge - eps
                        && $0.frame.minY - bottomEdge < gapTolY
                        && xOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minY).min() {
                    let pos = (bottomEdge + nearest) / 2
                    let xL = neighbors.map { max($0.frame.minX, a.frame.minX) }.min() ?? a.frame.minX
                    let xR = neighbors.map { min($0.frame.maxX, a.frame.maxX) }.max() ?? a.frame.maxX
                    result.append(.init(paneID: a.id, vertical: false, position: pos,
                                        hotRect: CGRect(x: xL, y: pos - above,
                                                        width: xR - xL, height: above + below)))
                }
            }
        }
        return result
    }

    private func yOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat { min(a.maxY, b.maxY) - max(a.minY, b.minY) }
    private func xOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat { min(a.maxX, b.maxX) - max(a.minX, b.minX) }

    // MARK: - Drag a pane's title bar onto another pane to swap them

    private var swapSourceID: TmuxPaneID?
    private var swapTargetID: TmuxPaneID? {
        didSet {
            guard oldValue != swapTargetID else { return }
            if let old = oldValue { paneControllers[old]?.isSwapTarget = false }
            if let new = swapTargetID { paneControllers[new]?.isSwapTarget = true }
        }
    }

    /// The pane under a window-coordinate point, excluding the dragged one. Pane
    /// frames live in `contentView`, so convert the window point in first.
    private func swapTarget(atWindowPoint p: CGPoint, excluding source: TmuxPaneID) -> TmuxPaneID? {
        let local = contentView.convert(p, from: nil)
        return paneControllers.first { id, vc in
            id != source && !vc.view.isHidden && vc.view.frame.contains(local)
        }?.key
    }

    private func handleTitleSwap(source paneID: TmuxPaneID, phase: TitleDragPhase) {
        // Swapping only makes sense between visible tiles. In focus / single-pane
        // layout there's nothing to swap with, so ignore the drag.
        guard !isFocusLayout else { return }
        switch phase {
        case .began:
            swapSourceID = paneID
            paneControllers[paneID]?.view.alpha = 0.6
        case .moved(let p):
            swapTargetID = swapTarget(atWindowPoint: p, excluding: paneID)
        case .ended(let p):
            if let target = swapTarget(atWindowPoint: p, excluding: paneID) {
                viewModel?.swapPanes(paneID, with: target)
            }
            endSwap(paneID)
        case .cancelled:
            endSwap(paneID)
        }
    }

    private func endSwap(_ paneID: TmuxPaneID) {
        paneControllers[paneID]?.view.alpha = 1.0
        swapTargetID = nil
        swapSourceID = nil
    }

    // MARK: - Page sizing & content offset

    /// Focus / single-pane title bar height (a comfortable touch target). Tiled
    /// mode uses one cell instead — see `layoutTiles`.
    private var titleBarH: CGFloat { TerminalContainerVC.defaultTitleBarHeight }

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
    /// Cell-exact: width maps cells 1:1; height is the grid plus exactly ONE
    /// title bar (one cell) — stacked panes' title bars reuse tmux's divider
    /// rows, so only the top bar adds height (see `layoutTiles`).
    private func pageSizeForTiles(totalCols: CGFloat, totalRows: CGFloat) -> CGSize {
        let rect = pageRect
        guard sizingMode == .pinned, let ppc = pointsPerCell else { return rect.size }
        return CGSize(width: totalCols * ppc.width,
                      height: (totalRows + 1) * ppc.height)
    }

    /// Place the content view at the clamped pan offset. Page ≤ viewport → pinned
    /// top-left, no scroll (PRD §2.2); page > viewport → pannable.
    private func setContentFrame(_ page: CGSize) {
        let rect = pageRect
        // The keyboard shrinks the usable viewport height (not the page). Clamp
        // against that reduced height so the content can pan up far enough to
        // lift the active pane's input above the keyboard; with no keyboard,
        // keyboardOverlap is 0 and this is the plain page-rect clamp.
        let usableH = rect.height - keyboardOverlap
        let minX = min(0, rect.width - page.width)
        let minY = min(0, usableH - page.height)
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
    /// Cell-exact tiling reserves exactly ONE cell of height for the top title
    /// bar (stacked panes reuse divider rows), so the usable terminal grid is
    /// the viewport minus a single cell row.
    private func recomputeTilesClientSize() {
        guard let cellPx else { return }
        let rect = pageRect
        guard rect.width > 0, rect.height > 0 else { return }
        let scale = displayScale
        let cols = max(Int((rect.width * scale) / cellPx.width), 2)
        let rows = max(Int((rect.height * scale) / cellPx.height) - 1, 1)
        pushClientSize(cols: cols, rows: rows)
    }

    /// Position the floating toolbar above the keyboard / focused pane. The pane
    /// frames live in the (possibly panned) content view, so offset into view
    /// coordinates.
    private func positionFloatingToolbar() {
        guard !floatingToolbar.isHidden else { return }
        let activeVC = focusedOrActiveVC
        refreshFloatingToolbarActions(for: activeVC)
        let paneFrame = activeVC?.view.frame ?? .zero
        let origin = contentView.frame.origin
        let anchor = CGRect(x: paneFrame.minX + origin.x, y: paneFrame.minY + origin.y,
                            width: paneFrame.width, height: paneFrame.height)
        let bottomSafe = view.safeAreaInsets.bottom
        let reserve = max(keyboardInsetBottom, bottomSafe)
        let containerBounds = CGRect(x: 0, y: 0, width: view.bounds.width,
                                     height: max(0, view.bounds.height - reserve))
        let tbh = activeVC?.titleBarHeight ?? TerminalContainerVC.defaultTitleBarHeight
        floatingToolbar.updatePosition(paneFrame: anchor, titleBarHeight: tbh,
                                       containerBounds: containerBounds, animated: false)
    }

    /// Point the floating toolbar's zoom + menu at the active pane. Pane actions
    /// only exist for tmux panes (a non-tmux single pane has nothing to split or
    /// zoom), so the action group is hidden otherwise.
    private func refreshFloatingToolbarActions(for activeVC: TerminalContainerVC?) {
        let isTmuxPane = activeVC?.paneVM != nil
        floatingToolbar.showsPaneActions = isTmuxPane
        guard isTmuxPane, let activeVC else { return }
        floatingToolbar.menuButton.menu = activeVC.paneMenu
        floatingToolbar.isZoomed = viewModel?.zoomedPaneID != nil
        floatingToolbar.onZoomTap = { [weak activeVC] in activeVC?.onToggleZoom?() }
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

// MARK: - Divider overlay (drag to resize)

/// A transparent overlay over the tiled panes. It is touch-transparent except
/// within a few points of a divider between two adjacent panes, where it claims
/// the touch to drag-resize them (sends tmux `resize-pane`). Everywhere else,
/// touches fall through to the panes. iOS mirror of the macOS `DividerOverlay`.
final class TileDividerOverlay: UIView {
    /// A draggable boundary: the pane that owns it, orientation, and hot rect.
    struct Divider {
        let paneID: TmuxPaneID
        let vertical: Bool    // true = vertical line, drags left/right
        let position: CGFloat // x (vertical) or y (horizontal), in points
        let hotRect: CGRect
    }

    /// Touch grab sizes (the mouse-era macOS overlay uses 10). Vertical dividers
    /// are CENTRED on the line. Horizontal dividers STRADDLE it — generous above
    /// (the upper pane's free surface) but only a little below, so the band sits
    /// on the border yet barely covers the lower pane's title bar, which is the
    /// drag-to-swap handle.
    static let hotThicknessV: CGFloat = 34
    static let hotAboveLine: CGFloat = 26
    static let hotBelowLine: CGFloat = 6

    var dividers: [Divider] = [] { didSet { setNeedsDisplay() } }
    /// Points per tmux cell, set by the host so drag distance → cell delta.
    var pointsPerCell: CGPoint?
    /// (paneID, vertical, signed incremental cell delta) during a live drag.
    var onResize: ((TmuxPaneID, Bool, Int) -> Void)?

    private var dragDivider: Divider?
    private var dragStart: CGPoint = .zero
    private var dragSentCells = 0
    private var dragLivePos: CGFloat?

    private static let accent = UIColor(red: 0.20, green: 0.80, blue: 0.55, alpha: 1.0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func divider(at point: CGPoint) -> Divider? {
        dividers.first { $0.hotRect.contains(point) }
    }

    // Transparent except over a divider hot zone, so panes get all other touches.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        divider(at: point) != nil
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            let p = g.location(in: self)
            dragDivider = divider(at: p)
            dragStart = p
            dragSentCells = 0
            dragLivePos = dragDivider.map { $0.vertical ? p.x : p.y }
            setNeedsDisplay()
        case .changed:
            guard let d = dragDivider, let ppc = pointsPerCell else { return }
            let p = g.location(in: self)
            dragLivePos = d.vertical ? p.x : p.y
            setNeedsDisplay()
            let deltaPts = d.vertical ? (p.x - dragStart.x) : (p.y - dragStart.y)
            let perCell = d.vertical ? ppc.x : ppc.y
            guard perCell > 0 else { return }
            let totalCells = Int((deltaPts / perCell).rounded())
            let incremental = totalCells - dragSentCells
            guard incremental != 0 else { return }
            dragSentCells = totalCells
            onResize?(d.paneID, d.vertical, incremental)
        default:
            dragDivider = nil
            dragSentCells = 0
            dragLivePos = nil
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        for d in dividers {
            stroke(d, at: d.position, color: UIColor(white: 1, alpha: 0.30), width: 1.5)
        }
        // The line being dragged tracks the finger (tmux relayout lags), drawn in
        // the accent colour so the drag is clearly visible.
        if let d = dragDivider, let pos = dragLivePos {
            stroke(d, at: pos, color: Self.accent, width: 2)
        }
    }

    private func stroke(_ d: Divider, at pos: CGFloat, color: UIColor, width: CGFloat) {
        color.setStroke()
        let path = UIBezierPath()
        path.lineWidth = width
        if d.vertical {
            path.move(to: CGPoint(x: pos, y: d.hotRect.minY))
            path.addLine(to: CGPoint(x: pos, y: d.hotRect.maxY))
        } else {
            path.move(to: CGPoint(x: d.hotRect.minX, y: pos))
            path.addLine(to: CGPoint(x: d.hotRect.maxX, y: pos))
        }
        path.stroke()
    }
}
