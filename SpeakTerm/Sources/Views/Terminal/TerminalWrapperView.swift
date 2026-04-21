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

            if viewModel.isTmuxReady {
                MultiPaneView(viewModel: viewModel, voiceController: voiceController)
            } else {
                SinglePaneView(viewModel: viewModel)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
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
        .alert("Connection Error", isPresented: $viewModel.showError) {
            Button("Retry") { Task { await viewModel.connect() } }
            Button("Dismiss", role: .cancel) { onDismiss() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    // MARK: - iOS-native Top Bar with glass pills

    private var topBar: some View {
        HStack(spacing: 4) {
            // Back / Close button
            GlassPillButton(action: onDismiss) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Hosts")
                        .font(.system(size: 17, weight: .regular))
                }
                .foregroundStyle(Color.stAccent)
            }

            // Center: nav title with host subtitle
            navTitle
                .frame(maxWidth: .infinity)

            // Mode toggle pill
            GlassPillButton(action: {
                viewModel.toggleInputMode()
                if viewModel.inputMode == .voice {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }) {
                Group {
                    if viewModel.inputMode == .voice {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14))
                    } else {
                        Image(systemName: "keyboard")
                            .font(.system(size: 14))
                    }
                }
                .foregroundStyle(viewModel.inputMode == .voice ? Color.stAccent : Color.stInk)
            }
            .glassHighlight(viewModel.inputMode == .voice)

            // Action menu pill (splits + settings)
            Menu {
                if viewModel.isTmuxReady {
                    Button(action: { viewModel.splitPane(horizontal: true) }) {
                        Label("Split Horizontal", systemImage: "rectangle.split.1x2")
                    }
                    Button(action: { viewModel.splitPane(horizontal: false) }) {
                        Label("Split Vertical", systemImage: "rectangle.split.2x1")
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
                }
                Button(action: { showSettings = true }) {
                    Label("Settings", systemImage: "gear")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.stInk)
                    .frame(minWidth: 32, minHeight: 32)
                    .padding(.horizontal, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(.black.opacity(0.01)) // tap area
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.stLineO)
                .frame(height: 0.5)
        }
    }

    private var navTitle: some View {
        VStack(spacing: 1) {
            Text(host.displayName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.stInk)
                .lineLimit(1)

            HStack(spacing: 4) {
                connectionDot
                Text("\(host.hostname)")
                    .lineLimit(1)
                if viewModel.isTmuxReady {
                    Text("·")
                        .foregroundStyle(Color.stInkMute)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.stInkDim)
        }
    }

    @ViewBuilder
    private var connectionDot: some View {
        switch viewModel.connectionState {
        case .connected:
            Circle().fill(Color.stGreen)
                .frame(width: 5, height: 5)
                .shadow(color: Color.stGreen.opacity(0.6), radius: 2)
        case .connecting:
            ProgressView().tint(.white).scaleEffect(0.5)
        case .failed:
            Circle().fill(Color.stRed).frame(width: 5, height: 5)
        case .disconnected:
            Circle().fill(Color.stInkMute).frame(width: 5, height: 5)
        }
    }
}

// MARK: - Glass Pill Button

/// iOS-native glass pill button with blur + saturate material
struct GlassPillButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    var highlighted: Bool = false

    var body: some View {
        Button(action: action) {
            content
                .frame(minWidth: 32, minHeight: 32)
                .padding(.horizontal, 6)
                .background(
                    highlighted
                        ? AnyShapeStyle(Color.stAccent.opacity(0.22))
                        : AnyShapeStyle(.ultraThinMaterial)
                )
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
    }

    func glassHighlight(_ on: Bool) -> GlassPillButton {
        var copy = self
        copy.highlighted = on
        return copy
    }
}

// MARK: - Single Pane (non-tmux fallback)

struct SinglePaneView: UIViewControllerRepresentable {
    let viewModel: TerminalViewModel

    func makeUIViewController(context: Context) -> TerminalContainerVC {
        let vc = TerminalContainerVC()
        vc.bindToTerminalVM(viewModel)
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
    let voiceController: VoiceInputController

    // Observe stateVersion so SwiftUI triggers updateUIViewController on state polls
    var stateVersion: Int { viewModel.stateVersion }

    func makeUIViewController(context: Context) -> MultiPaneContainerVC {
        let vc = MultiPaneContainerVC()
        vc.viewModel = viewModel
        vc.voiceController = voiceController
        vc.setupPanes()
        return vc
    }

    func updateUIViewController(_ vc: MultiPaneContainerVC, context: Context) {
        vc.updatePanes()
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

    // Focus mode
    private var focusedPaneID: TmuxPaneID?
    private var preFocusZoom: CGFloat = 1.0
    private var preFocusOffset: CGPoint = .zero
    private var exitFocusBar: UIView?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.TermDark.bg
        setupScrollView()
        setupGestureCoordinator()
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
        scrollView.backgroundColor = STTheme.TermDark.bg
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = false
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2

        canvasView.backgroundColor = STTheme.TermDark.bg
        scrollView.addSubview(canvasView)
        view.addSubview(scrollView)
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

    private func centerCanvasIfNeeded() {
        let bSize = scrollView.bounds.size
        let cSize = scrollView.contentSize
        let ox = max((bSize.width - cSize.width) / 2, 0)
        let oy = max((bSize.height - cSize.height) / 2, 0)
        canvasView.frame.origin = CGPoint(x: ox, y: oy)
    }

    // MARK: - Fit to Screen

    func fitToScreen(animated: Bool = true) {
        let cs = canvasView.frame.size
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

    // MARK: - Focus Mode

    func enterFocusMode(paneID: TmuxPaneID) {
        guard let vc = paneControllers[paneID] else { return }
        focusedPaneID = paneID
        preFocusZoom = scrollView.zoomScale
        preFocusOffset = scrollView.contentOffset

        for (id, c) in paneControllers where id != paneID {
            UIView.animate(withDuration: 0.25) { c.view.alpha = 0 }
        }

        let pf = vc.view.frame
        let vs = scrollView.bounds.size
        let scale = min(max(min(vs.width / pf.width, vs.height / pf.height),
                           scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        UIView.animate(withDuration: 0.3) {
            self.scrollView.zoomScale = scale
            let sf = CGRect(x: pf.origin.x * scale, y: pf.origin.y * scale,
                           width: pf.width * scale, height: pf.height * scale)
            self.scrollView.scrollRectToVisible(sf, animated: false)
        }
        showExitFocusBar()
    }

    func exitFocusMode() {
        guard focusedPaneID != nil else { return }
        focusedPaneID = nil
        for (_, c) in paneControllers {
            UIView.animate(withDuration: 0.25) { c.view.alpha = 1 }
        }
        UIView.animate(withDuration: 0.3) {
            self.scrollView.zoomScale = self.preFocusZoom
            self.scrollView.contentOffset = self.preFocusOffset
        }
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

    @objc private func exitFocusTapped() { exitFocusMode() }

    private func hideExitFocusBar() {
        exitFocusBar?.removeFromSuperview()
        exitFocusBar = nil
    }

    // MARK: - Pane Management

    func setupPanes() {
        guard let viewModel else { return }
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

                // Show/hide floating quick keys for awaiting panes
                let keys: [QuickKey] = isActive ? viewModel.stateDetection.quickKeys(for: state) : []
                vc.updateQuickKeys(for: state, keys: keys)

                UIView.animate(withDuration: 0.2) {
                    vc.view.layer.borderWidth = borderWidth
                    vc.view.layer.borderColor = borderColor.cgColor
                    if self.focusedPaneID == nil {
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
            UIAction(title: "Split Horizontal", image: UIImage(systemName: "rectangle.split.1x2")) { [weak self] _ in
                self?.viewModel?.splitPane(horizontal: true)
            },
            UIAction(title: "Split Vertical", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
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

        paneControllers[paneVM.paneID] = vc

        // Keep gesture overlay on top of all pane views
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
        guard let viewModel else { return }
        let panes = viewModel.paneViewModels.map(\.pane)
        guard !panes.isEmpty else { return }

        let cell = cellSize
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
