import SwiftUI

/// Bridges the UIKit terminal views into SwiftUI navigation.
struct TerminalWrapperView: View {
    let host: Host
    let onDismiss: () -> Void

    @StateObject private var viewModel: TerminalViewModel
    @StateObject private var voiceController = VoiceInputController()
    @EnvironmentObject private var hostStore: HostStore
    @State private var showSettings = false

    init(host: Host, onDismiss: @escaping () -> Void) {
        self.host = host
        self.onDismiss = onDismiss
        _viewModel = StateObject(wrappedValue: TerminalViewModel(host: host))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            MultiPaneView(viewModel: viewModel, voiceController: voiceController)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(true)
        .onAppear {
            hostStore.markConnected(host)
            voiceController.onResult = { [weak viewModel] result in
                viewModel?.handleVoiceResult(result)
            }
        }
        .onDisappear {
            viewModel.disconnect()
        }
        .overlay {
            if voiceController.showOverlay {
                GeometryReader { geo in
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Connection Error", isPresented: $viewModel.showError) {
            Button("Retry") { Task { await viewModel.connect() } }
            Button("Dismiss", role: .cancel) { onDismiss() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Back button — standard iOS style
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Hosts")
                        .font(.body)
                }
            }

            Spacer()

            // Center title
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

            // Mode toggle
            Button(action: {
                viewModel.toggleInputMode()
                if viewModel.inputMode == .voice {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }) {
                Image(systemName: viewModel.inputMode == .voice ? "mic.fill" : "keyboard")
                    .font(.system(size: 16))
                    .foregroundColor(viewModel.inputMode == .voice ? .accentColor : .secondary)
            }

            // Action menu
            Menu {
                if viewModel.isTmuxReady {
                    Button(action: { viewModel.splitPane(horizontal: true) }) {
                        Label("Split Horizontal", systemImage: "rectangle.split.2x1")
                    }
                    Button(action: { viewModel.splitPane(horizontal: false) }) {
                        Label("Split Vertical", systemImage: "rectangle.split.1x2")
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
                        onDismiss()
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

// MARK: - Terminal Pane Container

struct MultiPaneView: UIViewControllerRepresentable {
    @ObservedObject var viewModel: TerminalViewModel
    let voiceController: VoiceInputController

    // Observe stateVersion so SwiftUI triggers updateUIViewController on state polls
    var stateVersion: Int { viewModel.stateVersion }

    func makeUIViewController(context: Context) -> MultiPaneContainerVC {
        let vc = MultiPaneContainerVC()
        vc.viewModel = viewModel
        vc.voiceController = voiceController

        if viewModel.isTmuxReady {
            vc.setupPanes()
        } else {
            // Non-tmux or not yet ready: create a single full-screen pane
            vc.setupSinglePane()
            // Trigger connection
            Task { @MainActor in
                if case .disconnected = viewModel.connectionState {
                    await viewModel.connect()
                }
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: MultiPaneContainerVC, context: Context) {
        if viewModel.isTmuxReady {
            // Transition from single pane to tmux panes if needed
            if vc.singlePaneVC != nil {
                vc.setupPanes()
            } else {
                vc.updatePanes()
            }
        }
    }
}

// MARK: - Multi Pane Container

/// Canvas container with UIScrollView for zoom/pan.
/// All gesture logic is delegated to GestureCoordinator.
final class MultiPaneContainerVC: UIViewController, UIScrollViewDelegate {
    var viewModel: TerminalViewModel?
    var voiceController: VoiceInputController?
    private(set) var paneControllers: [TmuxPaneID: TerminalContainerVC] = [:]

    private let scrollView = UIScrollView()
    private let canvasView = UIView()
    private let gestureCoordinator = GestureCoordinator()

    // Focus mode (tmux zoom)
    private var focusedPaneID: TmuxPaneID?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term.bg
        setupScrollView()
        setupGestureCoordinator()
        setupKeyboardObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return }

        keyboardInsetBottom = frame.height
        UIView.animate(withDuration: duration) {
            self.scrollView.contentInset.bottom = self.keyboardInsetBottom
            self.scrollView.verticalScrollIndicatorInsets.bottom = self.keyboardInsetBottom
        }

        // Scroll active pane into view above keyboard
        if let activePaneID = viewModel?.activePaneID,
           let vc = paneControllers[activePaneID] {
            scrollView.scrollRectToVisible(vc.view.frame, animated: true)
        }
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        guard let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return }
        keyboardInsetBottom = 0
        UIView.animate(withDuration: duration) {
            self.scrollView.contentInset.bottom = 0
            self.scrollView.verticalScrollIndicatorInsets.bottom = 0
        } completion: { _ in
            self.fitToScreen(animated: true)
        }
    }

    private func setupScrollView() {
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.2
        scrollView.maximumZoomScale = 3.0
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = STTheme.term.bg
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = false
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2

        canvasView.backgroundColor = STTheme.term.bg
        scrollView.addSubview(canvasView)
        view.addSubview(scrollView)

        // Double-tap on scroll view itself → fit to screen (recovery when canvas is off-screen)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleScrollViewDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    @objc private func handleScrollViewDoubleTap() {
        fitToScreen(animated: true)
    }

    private func setupGestureCoordinator() {
        gestureCoordinator.getInputMode = { [weak self] in
            self?.viewModel?.inputMode ?? .voice
        }
        gestureCoordinator.voiceController = voiceController

        gestureCoordinator.onSelectPane = { [weak self] paneID in
            self?.viewModel?.selectPane(paneID)
            self?.updatePaneVisuals()
        }
        gestureCoordinator.onFocusPane = { [weak self] paneID in
            self?.enterFocusMode(paneID: paneID)
        }
        gestureCoordinator.onExitFocus = { [weak self] in
            self?.exitFocusMode()
        }
        gestureCoordinator.onFitToScreen = { [weak self] in
            self?.fitToScreen(animated: true)
        }
        gestureCoordinator.onDismissKeyboard = { [weak self] in
            self?.view.endEditing(true)
        }
        gestureCoordinator.isInFocusMode = { [weak self] in
            self?.focusedPaneID != nil
        }
        gestureCoordinator.paneAt = { [weak self] point in
            self?.paneControllerAt(point: point)
        }
        gestureCoordinator.allPaneFrames = { [weak self] in
            guard let self else { return [] }
            return self.paneControllers.map { ($0.key, $0.value.view.frame) }
        }
        gestureCoordinator.onResizePane = { [weak self] paneID, direction, amount in
            self?.viewModel?.resizePaneBy(paneID, direction: direction, amount: amount)
        }

        gestureCoordinator.install(on: canvasView)
    }

    /// Find pane at a point in canvas coordinates
    private func paneControllerAt(point: CGPoint) -> (TmuxPaneID, TerminalContainerVC)? {
        for (paneID, vc) in paneControllers {
            if vc.view.frame.contains(point) {
                return (paneID, vc)
            }
        }
        return nil
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvasView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerCanvasIfNeeded() }

    /// Track keyboard inset separately so centering logic doesn't clobber it
    private var keyboardInsetBottom: CGFloat = 0

    private func centerCanvasIfNeeded() {
        let bSize = scrollView.bounds.size
        let cSize = scrollView.contentSize
        let ox = max((bSize.width - cSize.width) / 2, 0)
        let oy = max((bSize.height - keyboardInsetBottom - cSize.height) / 2, 0)
        canvasView.frame.origin = CGPoint(x: ox, y: oy)
    }

    // MARK: - Fit to Screen

    func fitToScreen(animated: Bool = true) {
        // Use bounds (unscaled) size — frame.size is already scaled by zoomScale
        let cs = canvasView.bounds.size
        guard cs.width > 0, cs.height > 0 else { return }
        let vs = scrollView.bounds.size
        let scale = min(max(min(vs.width / cs.width, vs.height / cs.height),
                           scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        if animated {
            UIView.animate(withDuration: 0.3) {
                self.scrollView.zoomScale = scale
                self.centerCanvasIfNeeded()
            }
        } else {
            scrollView.zoomScale = scale
            centerCanvasIfNeeded()
        }
    }

    // MARK: - Focus Mode (tmux zoom)

    /// Toggle tmux zoom on a pane — the pane fills the entire window.
    func enterFocusMode(paneID: TmuxPaneID) {
        guard focusedPaneID == nil else { return }
        focusedPaneID = paneID
        viewModel?.toggleZoom(paneID)
    }

    func exitFocusMode() {
        guard let paneID = focusedPaneID else { return }
        focusedPaneID = nil
        viewModel?.toggleZoom(paneID)
    }

    // MARK: - Pane Management

    /// Non-tmux: create a single TerminalContainerVC bound directly to the TerminalViewModel
    func setupSinglePane() {
        guard let viewModel else { return }
        let vc = TerminalContainerVC()
        vc.bindToTerminalVM(viewModel)

        addChild(vc)
        canvasView.addSubview(vc.view)
        vc.didMove(toParent: self)

        // Hide tmux-only buttons
        vc.titleBar.focusButton.isHidden = true
        vc.titleBar.menuButton.isHidden = true

        // Attach gestures (quick keys, voice, tap)
        let dummyID = TmuxPaneID(0)
        gestureCoordinator.attachPaneGestures(to: vc, paneID: dummyID)
        singlePaneVC = vc

        gestureCoordinator.bringOverlayToFront()
    }

    private(set) var singlePaneVC: TerminalContainerVC?

    func setupPanes() {
        guard let viewModel else { return }
        // Remove single pane if transitioning to tmux
        if let single = singlePaneVC {
            single.willMove(toParent: nil)
            single.view.removeFromSuperview()
            single.removeFromParent()
            singlePaneVC = nil
        }
        for paneVM in viewModel.paneViewModels { addPaneController(for: paneVM) }
        layoutPanes()
        DispatchQueue.main.async { self.fitToScreen(animated: false) }
    }

    func updatePanes() {
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

        updatePaneVisuals()
        layoutPanes()
    }

    private func updatePaneVisuals() {
        guard let viewModel else { return }
        for paneVM in viewModel.paneViewModels {
            if let vc = paneControllers[paneVM.paneID] {
                let isActive = paneVM.isActive
                let state = paneVM.paneState
                let borderColor = STTheme.paneBorder(for: state, active: isActive)
                let borderWidth = STTheme.paneBorderWidth(active: isActive)

                vc.updatePaneState(state, active: isActive)

                // Active pane always shows quick keys
                vc.showQuickKeys(isActive)

                // When zoomed, hide all panes except the zoomed one
                let isZoomed = self.focusedPaneID != nil
                let isZoomedPane = paneVM.paneID == self.focusedPaneID

                UIView.animate(withDuration: 0.2) {
                    vc.view.layer.borderWidth = borderWidth
                    vc.view.layer.borderColor = borderColor.cgColor
                    if isZoomed {
                        vc.view.isHidden = !isZoomedPane
                    } else {
                        vc.view.isHidden = false
                        vc.view.alpha = isActive ? 1.0 : 0.85
                    }
                }
            }
        }
    }

    private func addPaneController(for paneVM: PaneViewModel) {
        let paneID = paneVM.paneID
        let vc = TerminalContainerVC()
        vc.bindToPaneVM(paneVM)

        // Wire focus button on title bar
        vc.titleBar.focusButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.focusedPaneID != nil { self.exitFocusMode() }
            else { self.enterFocusMode(paneID: paneID) }
        }, for: .touchUpInside)

        // Wire menu button on title bar — context menu for pane actions
        vc.titleBar.menuButton.showsMenuAsPrimaryAction = true
        vc.titleBar.menuButton.menu = UIMenu(children: [
            UIAction(title: "Split Horizontal", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                self?.viewModel?.splitPane(horizontal: true)
            },
            UIAction(title: "Split Vertical", image: UIImage(systemName: "rectangle.split.1x2")) { [weak self] _ in
                self?.viewModel?.splitPane(horizontal: false)
            },
            UIAction(title: "Close Pane", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.viewModel?.closePane(paneID)
            },
        ])

        addChild(vc)
        canvasView.addSubview(vc.view)
        vc.didMove(toParent: self)

        vc.view.layer.cornerRadius = 4
        vc.view.clipsToBounds = true

        // Attach per-pane gestures (tap to select, long-press for voice)
        // SwiftTerm's native scroll and selection remain enabled
        gestureCoordinator.attachPaneGestures(to: vc, paneID: paneID)

        paneControllers[paneVM.paneID] = vc

        // Keep canvas overlay on top of all pane views
        gestureCoordinator.bringOverlayToFront()
    }

    // MARK: - Layout

    private var cellSize: CGSize {
        let font = UIFont.monospacedSystemFont(ofSize: STTheme.terminalFontSize, weight: .regular)
        let sample = NSString(string: "M")
        let size = sample.size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func layoutPanes() {
        // Single pane mode: fill the view
        if let single = singlePaneVC {
            let size = view.bounds.size
            canvasView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
            single.view.frame = CGRect(origin: .zero, size: size)
            single.showQuickKeys(true)
            gestureCoordinator.updateOverlayFrame(CGRect(origin: .zero, size: size))
            return
        }

        // Multi-pane tmux mode
        guard let viewModel else { return }
        let panes = viewModel.paneViewModels.map(\.pane)
        guard !panes.isEmpty else { return }

        let cell = cellSize
        gestureCoordinator.cellSize = cell
        for paneVM in viewModel.paneViewModels {
            guard let vc = paneControllers[paneVM.paneID] else { continue }
            let p = paneVM.pane
            let frame = CGRect(
                x: CGFloat(p.x) * cell.width,
                y: CGFloat(p.y) * cell.height,
                width: CGFloat(p.width) * cell.width,
                height: CGFloat(p.height) * cell.height
            )
            vc.view.frame = frame.insetBy(dx: 1, dy: 1)
        }

        let maxRight = panes.map { $0.x + $0.width }.max() ?? 80
        let maxBottom = panes.map { $0.y + $0.height }.max() ?? 24
        let canvasSize = CGSize(
            width: CGFloat(maxRight) * cell.width,
            height: CGFloat(maxBottom) * cell.height
        )
        canvasView.frame = CGRect(origin: .zero, size: canvasSize)
        scrollView.contentSize = canvasSize
        gestureCoordinator.updateOverlayFrame(CGRect(origin: .zero, size: canvasSize))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        layoutPanes()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.fitToScreen(animated: false) })
    }
}
