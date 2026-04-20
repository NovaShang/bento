import SwiftUI

extension Notification.Name {
    static let voiceLongPress = Notification.Name("voiceLongPress")
}

/// Bridges the UIKit terminal views into SwiftUI navigation.
/// Supports both single-pane (non-tmux) and multi-pane (tmux) modes.
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

            if viewModel.isTmuxReady {
                MultiPaneView(viewModel: viewModel)
            } else {
                SinglePaneView(viewModel: viewModel)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .statusBarHidden(true)
        .onAppear {
            hostStore.markConnected(host)
        }
        .onDisappear {
            viewModel.disconnect()
        }
        .overlay {
            if voiceController.showOverlay {
                VoiceOverlayView(
                    transcript: voiceController.transcript,
                    activeDirection: voiceController.activeDirection,
                    isRecording: voiceController.isRecording
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            voiceController.onResult = { [weak viewModel] result in
                viewModel?.handleVoiceResult(result)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceLongPress)) { notification in
            guard let info = notification.userInfo,
                  let stateRaw = info["state"] as? Int,
                  let state = UIGestureRecognizer.State(rawValue: stateRaw),
                  let x = info["x"] as? CGFloat,
                  let y = info["y"] as? CGFloat else { return }
            voiceController.handleLongPress(state: state, location: CGPoint(x: x, y: y))
        }
        .alert("Connection Error", isPresented: $viewModel.showError) {
            Button("Retry") {
                Task { await viewModel.connect() }
            }
            Button("Dismiss", role: .cancel) {
                onDismiss()
            }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }

            if viewModel.isTmuxReady {
                Menu {
                    Button("Split Horizontal") {
                        viewModel.splitPane(horizontal: true)
                    }
                    Button("Split Vertical") {
                        viewModel.splitPane(horizontal: false)
                    }

                    Divider()

                    Button("New Window") {
                        viewModel.newWindow()
                    }

                    if viewModel.windows.count > 1 {
                        Divider()
                        ForEach(viewModel.windows) { window in
                            Button(window.name) {
                                viewModel.selectWindow(window.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            Text(host.displayName)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            // Mode toggle button
            Button(action: { viewModel.toggleInputMode() }) {
                Image(systemName: viewModel.inputMode == .voice ? "mic.fill" : "keyboard")
                    .font(.title3)
                    .foregroundStyle(viewModel.inputMode == .voice ? .orange : .white)
            }

            // Settings
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }

            connectionIndicator
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.black.opacity(0.6))
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch viewModel.connectionState {
        case .connected:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .connecting:
            ProgressView().tint(.white).scaleEffect(0.7)
        case .failed:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .disconnected:
            Circle().fill(.gray).frame(width: 8, height: 8)
        }
    }
}

// MARK: - Single Pane (non-tmux fallback or pre-tmux)

struct SinglePaneView: UIViewControllerRepresentable {
    let viewModel: TerminalViewModel

    func makeUIViewController(context: Context) -> TerminalContainerVC {
        let vc = TerminalContainerVC()
        vc.bindToTerminalVM(viewModel)

        // Start connection after view is ready
        Task { @MainActor in
            if case .disconnected = viewModel.connectionState {
                await viewModel.connect()
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: TerminalContainerVC, context: Context) {}
}

// MARK: - Multi Pane (tmux mode)

struct MultiPaneView: UIViewControllerRepresentable {
    @ObservedObject var viewModel: TerminalViewModel

    func makeUIViewController(context: Context) -> MultiPaneContainerVC {
        let vc = MultiPaneContainerVC()
        vc.viewModel = viewModel
        vc.setupPanes()
        return vc
    }

    func updateUIViewController(_ vc: MultiPaneContainerVC, context: Context) {
        vc.updatePanes()
    }
}

/// UIKit container with a UIScrollView-based canvas that supports
/// pinch-zoom and two-finger pan. Panes are positioned at their
/// tmux coordinates on a logical canvas; the screen is a viewport.
final class MultiPaneContainerVC: UIViewController, UIScrollViewDelegate {
    var viewModel: TerminalViewModel?
    private var paneControllers: [TmuxPaneID: TerminalContainerVC] = [:]

    private let scrollView = UIScrollView()
    private let canvasView = UIView()

    // Focus mode state
    private var focusedPaneID: TmuxPaneID?
    private var preFocusZoom: CGFloat = 1.0
    private var preFocusOffset: CGPoint = .zero
    private var exitFocusBar: UIView?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupScrollView()
    }

    private func setupScrollView() {
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.2
        scrollView.maximumZoomScale = 3.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = false

        // Two-finger pan only — single finger passes through to terminal views
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2

        canvasView.backgroundColor = UIColor(white: 0.05, alpha: 1)
        scrollView.addSubview(canvasView)

        view.addSubview(scrollView)

        // Double-tap on empty canvas area → fit to screen
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(canvasDoubleTapped))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        canvasView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerCanvasIfNeeded()
    }

    /// Center the canvas when it's smaller than the viewport
    private func centerCanvasIfNeeded() {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize

        let offsetX = max((boundsSize.width - contentSize.width) / 2, 0)
        let offsetY = max((boundsSize.height - contentSize.height) / 2, 0)

        canvasView.frame.origin = CGPoint(x: offsetX, y: offsetY)
    }

    // MARK: - Fit to Screen

    @objc private func canvasDoubleTapped() {
        if focusedPaneID != nil {
            exitFocusMode()
        } else {
            fitToScreen(animated: true)
        }
    }

    func fitToScreen(animated: Bool = true) {
        let canvasSize = canvasView.frame.size
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }

        let viewportSize = scrollView.bounds.size
        let fitScale = min(
            viewportSize.width / canvasSize.width,
            viewportSize.height / canvasSize.height
        )

        let clampedScale = min(max(fitScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)

        if animated {
            UIView.animate(withDuration: 0.3) {
                self.scrollView.zoomScale = clampedScale
                self.centerCanvasIfNeeded()
            }
        } else {
            scrollView.zoomScale = clampedScale
            centerCanvasIfNeeded()
        }
    }

    // MARK: - Focus Mode

    func enterFocusMode(paneID: TmuxPaneID) {
        guard let vc = paneControllers[paneID] else { return }

        focusedPaneID = paneID
        preFocusZoom = scrollView.zoomScale
        preFocusOffset = scrollView.contentOffset

        // Hide other panes
        for (id, controller) in paneControllers where id != paneID {
            UIView.animate(withDuration: 0.25) {
                controller.view.alpha = 0
            }
        }

        // Zoom to fill viewport with this pane
        let paneFrame = vc.view.frame
        let viewportSize = scrollView.bounds.size
        let focusScale = min(
            viewportSize.width / paneFrame.width,
            viewportSize.height / paneFrame.height
        )
        let clampedScale = min(max(focusScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)

        UIView.animate(withDuration: 0.3) {
            self.scrollView.zoomScale = clampedScale
            let scaledFrame = CGRect(
                x: paneFrame.origin.x * clampedScale,
                y: paneFrame.origin.y * clampedScale,
                width: paneFrame.width * clampedScale,
                height: paneFrame.height * clampedScale
            )
            self.scrollView.scrollRectToVisible(scaledFrame, animated: false)
        }

        showExitFocusBar()
    }

    func exitFocusMode() {
        guard focusedPaneID != nil else { return }
        focusedPaneID = nil

        // Show all panes
        for (_, controller) in paneControllers {
            UIView.animate(withDuration: 0.25) {
                controller.view.alpha = 1
            }
        }

        // Restore zoom/offset
        UIView.animate(withDuration: 0.3) {
            self.scrollView.zoomScale = self.preFocusZoom
            self.scrollView.contentOffset = self.preFocusOffset
        }

        // Update active pane visuals (alpha)
        updatePaneVisuals()
        hideExitFocusBar()
    }

    private func showExitFocusBar() {
        let bar = UIView()
        bar.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
        bar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 32)
        bar.autoresizingMask = [.flexibleWidth]

        let label = UILabel()
        label.text = "Tap to exit focus"
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textAlignment = .center
        label.frame = bar.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bar.addSubview(label)

        let tap = UITapGestureRecognizer(target: self, action: #selector(exitFocusTapped))
        bar.addGestureRecognizer(tap)

        view.addSubview(bar)
        exitFocusBar = bar
    }

    @objc private func exitFocusTapped() {
        exitFocusMode()
    }

    private func hideExitFocusBar() {
        exitFocusBar?.removeFromSuperview()
        exitFocusBar = nil
    }

    // MARK: - Pane Management

    func setupPanes() {
        guard let viewModel else { return }
        for paneVM in viewModel.paneViewModels {
            addPaneController(for: paneVM)
        }
        layoutPanes()

        // Fit to screen on first layout
        DispatchQueue.main.async {
            self.fitToScreen(animated: false)
        }
    }

    func updatePanes() {
        guard let viewModel else { return }

        let currentIDs = Set(paneControllers.keys)
        let newIDs = Set(viewModel.paneViewModels.map(\.paneID))

        // Remove old panes
        for id in currentIDs.subtracting(newIDs) {
            if let vc = paneControllers.removeValue(forKey: id) {
                vc.willMove(toParent: nil)
                vc.view.removeFromSuperview()
                vc.removeFromParent()
            }
        }

        // Add new panes
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
                UIView.animate(withDuration: 0.2) {
                    vc.view.layer.borderWidth = isActive ? 2 : 0.5
                    vc.view.layer.borderColor = isActive
                        ? UIColor.systemBlue.cgColor
                        : UIColor.systemGray.withAlphaComponent(0.3).cgColor
                    // Inactive panes are dimmed (unless in focus mode)
                    if self.focusedPaneID == nil {
                        vc.view.alpha = isActive ? 1.0 : 0.6
                    }
                }
            }
        }
    }

    private func addPaneController(for paneVM: PaneViewModel) {
        let paneID = paneVM.paneID
        let vc = TerminalContainerVC()
        vc.bindToPaneVM(paneVM)

        // Wire tap callbacks
        vc.onSingleTap = { [weak self] in
            self?.viewModel?.selectPane(paneID)
            self?.updatePaneVisuals()
        }
        vc.onDoubleTap = { [weak self] in
            guard let self else { return }
            if self.focusedPaneID != nil {
                self.exitFocusMode()
            } else {
                self.enterFocusMode(paneID: paneID)
            }
        }

        // Long-press for voice input
        vc.onLongPress = { [weak self] state, location in
            guard let self, self.viewModel?.inputMode == .voice else { return }
            // Select this pane first
            self.viewModel?.selectPane(paneID)
            self.updatePaneVisuals()
            // Forward to voice controller via notification
            NotificationCenter.default.post(
                name: .voiceLongPress,
                object: nil,
                userInfo: ["state": state.rawValue, "x": location.x, "y": location.y]
            )
        }

        addChild(vc)
        canvasView.addSubview(vc.view)
        vc.didMove(toParent: self)

        vc.view.layer.cornerRadius = 4
        vc.view.clipsToBounds = true

        paneControllers[paneVM.paneID] = vc
    }

    // MARK: - Layout

    /// Character cell size based on the terminal font
    private var cellSize: CGSize {
        let fontSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 14 : 12
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let sample = NSString(string: "M")
        let size = sample.size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func layoutPanes() {
        guard let viewModel else { return }

        let panes = viewModel.paneViewModels.map(\.pane)
        guard !panes.isEmpty else { return }

        let cell = cellSize

        // Position each pane at tmux coordinates on the canvas
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

        // Canvas size = tmux window extent
        let maxRight = panes.map { $0.x + $0.width }.max() ?? 80
        let maxBottom = panes.map { $0.y + $0.height }.max() ?? 24
        let canvasSize = CGSize(
            width: CGFloat(maxRight) * cell.width,
            height: CGFloat(maxBottom) * cell.height
        )
        canvasView.frame = CGRect(origin: .zero, size: canvasSize)
        scrollView.contentSize = canvasSize
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        layoutPanes()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.fitToScreen(animated: false)
        })
    }
}

