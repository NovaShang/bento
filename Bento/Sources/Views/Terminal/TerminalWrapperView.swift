import SwiftUI
import SwiftTmux

/// Bridges the UIKit terminal views into SwiftUI navigation.
/// The TerminalViewModel and VoiceInputController are owned by the parent
/// (HostSessionsView) and passed in — the session has already been picked
/// before this view is pushed.
struct TerminalWrapperView: View {
    @ObservedObject var viewModel: TerminalViewModel
    @ObservedObject var voiceController: VoiceInputController

    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false

    private var host: Host { viewModel.host }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            MultiPaneView(viewModel: viewModel, voiceController: voiceController)
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
            // Back button — pops back to the sessions list.
            Button(action: { dismiss() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Sessions")
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

// MARK: - Terminal Pane Container

struct MultiPaneView: UIViewControllerRepresentable {
    @ObservedObject var viewModel: TerminalViewModel
    @ObservedObject var voiceController: VoiceInputController

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

    /// Canvas pan + pinch-zoom gestures. When `true`, the user can two-finger
    /// pan and pinch the multi-pane tmux canvas; per-pane SwiftTerm pans are
    /// configured to defer to the scroll view's 2-finger pan so the gesture
    /// reliably wins regardless of which pane the fingers land on.
    private let canvasInteractionEnabled = true

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
        guard let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        // Convert to our view's coordinate space so we get the actual overlap,
        // not the raw screen-coord keyboard height (which doesn't account for
        // how far up the view itself sits above the screen bottom).
        let inView = view.convert(frameValue, from: nil)
        keyboardInsetBottom = max(0, view.bounds.maxY - inView.minY)
        animateForKeyboard(note)
        refreshKeyboardButtonIcons(keyboardUp: true)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardInsetBottom = 0
        animateForKeyboard(note)
        refreshKeyboardButtonIcons(keyboardUp: false)
    }

    private func refreshKeyboardButtonIcons(keyboardUp: Bool) {
        let symbol = keyboardUp ? "keyboard.chevron.compact.down" : "keyboard"
        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = UIImage(systemName: symbol, withConfiguration: cfg)
        for vc in paneControllers.values {
            vc.titleBar.keyboardButton.setImage(image, for: .normal)
        }
        singlePaneVC?.titleBar.keyboardButton.setImage(image, for: .normal)
    }

    private func animateForKeyboard(_ note: Notification) {
        let info = note.userInfo
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 0
        let opts = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: opts) {
            self.applyKeyboardInset()
            self.view.layoutIfNeeded()
        }
    }

    /// Re-position content so the active pane / cursor stays above the
    /// on-screen keyboard. Strategy depends on mode:
    ///
    /// - **Non-tmux single pane**: layoutPanes resizes the pane → SwiftTerm
    ///   reflows → SSH PTY SIGWINCHes.
    /// - **tmux single-pane / focus mode**: layoutPanes resizes the canvas to
    ///   the available area AND sends `refresh-client -C` to tmux so the
    ///   remote shell SIGWINCHes — same UX as non-tmux.
    /// - **tmux multi-pane (split, not focused)**: canvas geometry stays put
    ///   (server-side splits are authoritative). We only translate the canvas
    ///   up via centerCanvasIfNeeded and scroll the active pane's bottom into
    ///   view for the zoomed-canvas case.
    private func applyKeyboardInset() {
        if singlePaneVC != nil || shouldRenderAsSinglePane {
            layoutPanes()
            return
        }
        scrollView.contentInset.bottom = keyboardInsetBottom
        scrollView.verticalScrollIndicatorInsets.bottom = keyboardInsetBottom
        centerCanvasIfNeeded()

        guard keyboardInsetBottom > 0 else { return }
        if let activeID = viewModel?.activePaneID,
           let activeVC = paneControllers[activeID] {
            var rect = canvasView.convert(activeVC.view.frame, to: scrollView)
            rect = CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1)
            scrollView.scrollRectToVisible(rect, animated: false)
        }
    }

    private func setupScrollView() {
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.2
        scrollView.maximumZoomScale = 3.0
        scrollView.bouncesZoom = canvasInteractionEnabled
        scrollView.alwaysBounceVertical = canvasInteractionEnabled
        scrollView.alwaysBounceHorizontal = canvasInteractionEnabled
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = STTheme.term.bg
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = false
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2

        // Lock the canvas: disable user pan + pinch. fitToScreen() still works
        // programmatically (sets zoomScale directly).
        if !canvasInteractionEnabled {
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.pinchGestureRecognizer?.isEnabled = false
        }

        canvasView.backgroundColor = STTheme.term.bg
        scrollView.addSubview(canvasView)
        view.addSubview(scrollView)

        // Double-tap on scroll view → fit to screen (recovery when canvas
        // drifts off-screen). Skip when canvas is locked.
        if canvasInteractionEnabled {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleScrollViewDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            scrollView.addGestureRecognizer(doubleTap)
        }
    }

    @objc private func handleScrollViewDoubleTap() {
        fitToScreen(animated: true)
    }

    /// Toggle the keyboard against a specific pane. Called by per-pane
    /// title-bar keyboard buttons. If that pane is already focused, the
    /// keyboard is dismissed; otherwise it's brought up and focused there.
    private func toggleKeyboard(for vc: TerminalContainerVC) {
        guard let tv = vc.terminalView else { return }
        if tv.isFirstResponder {
            view.endEditing(true)
        } else {
            _ = tv.becomeFirstResponder()
        }
    }

    private func setupGestureCoordinator() {
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
        let oy: CGFloat
        if keyboardInsetBottom > 0 {
            // Bottom-anchor while the keyboard is up — the canvas's bottom edge
            // (where the cursor lives) sits flush against the keyboard top.
            // Mirrors the single-pane behavior: typing UX is the same whether
            // tmux is involved or not.
            oy = max(bSize.height - keyboardInsetBottom - cSize.height, 0)
        } else {
            oy = max((bSize.height - cSize.height) / 2, 0)
        }
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
        // Switch to single-pane layout: canvas fills viewport, tmux client
        // is resized to match. Same code path as a 1-pane session.
        UIView.animate(withDuration: 0.2) { self.layoutPanes() }
    }

    func exitFocusMode() {
        guard let paneID = focusedPaneID else { return }
        focusedPaneID = nil
        viewModel?.toggleZoom(paneID)
        // Drop back to multi-pane grid layout. fitToScreen so the full canvas
        // is visible again after the user exits focus.
        UIView.animate(withDuration: 0.2) {
            self.layoutPanes()
        } completion: { _ in
            self.fitToScreen(animated: true)
        }
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

        // Single pane has no concept of selection — always show quick keys.
        // Menu lives in the wrapper's top bar for non-tmux mode, so hide the
        // per-pane menu to avoid duplicate affordances. Voice stays per the
        // "always-visible" rule.
        vc.titleBar.isActivePane = true
        vc.titleBar.menuButton.isHidden = true
        vc.titleBar.voiceButton.addAction(UIAction { [weak self, weak vc] _ in
            guard let self, let vc else { return }
            self.view.endEditing(true)
            let btn = vc.titleBar.voiceButton
            let anchor = btn.superview?.convert(btn.center, to: nil) ?? .zero
            self.voiceController?.toggleRecording(anchorScreenPoint: anchor)
        }, for: .touchUpInside)
        vc.titleBar.keyboardButton.addAction(UIAction { [weak self, weak vc] _ in
            guard let self, let vc else { return }
            self.toggleKeyboard(for: vc)
        }, for: .touchUpInside)

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
        // Only fit-to-screen when we're in true multi-pane mode (canvas is the
        // tmux grid, possibly larger than viewport). Single-pane / focus mode
        // already fills the viewport at 1:1 via layoutPanes, so any further
        // zoom would just shrink it again.
        if !shouldRenderAsSinglePane {
            DispatchQueue.main.async { self.fitToScreen(animated: false) }
        }
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

        // Voice button: tap-to-toggle recording on THIS pane. Selects the pane
        // first so the transcript lands in the right place, then starts or
        // stops the recording (mirroring long-press behavior with no
        // directional modifier — plain text inject on stop).
        vc.titleBar.voiceButton.addAction(UIAction { [weak self, weak vc] _ in
            guard let self, let vc else { return }
            self.viewModel?.selectPane(paneID)
            self.view.endEditing(true)
            let btn = vc.titleBar.voiceButton
            let anchor = btn.superview?.convert(btn.center, to: nil) ?? .zero
            self.voiceController?.toggleRecording(anchorScreenPoint: anchor)
        }, for: .touchUpInside)

        // Keyboard button: selects this pane and toggles its first-responder.
        vc.titleBar.keyboardButton.addAction(UIAction { [weak self, weak vc] _ in
            guard let self, let vc else { return }
            self.viewModel?.selectPane(paneID)
            self.toggleKeyboard(for: vc)
        }, for: .touchUpInside)

        // Wire menu button on title bar — context menu for pane actions
        vc.titleBar.menuButton.showsMenuAsPrimaryAction = true
        vc.titleBar.menuButton.menu = makePaneMenu(for: paneID)

        addChild(vc)
        canvasView.addSubview(vc.view)
        vc.didMove(toParent: self)

        vc.view.layer.cornerRadius = 4
        vc.view.clipsToBounds = true

        // Attach per-pane gestures (tap to select, long-press for voice)
        // SwiftTerm's native scroll and selection remain enabled
        gestureCoordinator.attachPaneGestures(to: vc, paneID: paneID)

        // Make SwiftTerm's per-pane pan (scroll history) wait until the
        // canvas-level 2-finger pan has had a chance to fail. Without this,
        // two fingers landing on two different panes each get claimed by
        // that pane's SwiftTerm pan as an independent 1-finger scroll, and
        // the scroll view's 2-finger pan never sees them as a pair.
        if canvasInteractionEnabled {
            deferSwiftTermPansToCanvas(in: vc)
        }

        paneControllers[paneVM.paneID] = vc

        // Keep canvas overlay on top of all pane views
        gestureCoordinator.bringOverlayToFront()
    }

    /// Set up gesture priority so every SwiftTerm pan on a pane defers to the
    /// canvas-level 2-finger pan + pinch. SwiftTerm's TerminalView **is** a
    /// UIScrollView, so its built-in `panGestureRecognizer` (which accepts
    /// any touch count, including 2 fingers as scrollback) needs the same
    /// dependency — otherwise two fingers landing on one pane get claimed by
    /// that pane's scroll instead of bubbling up to the canvas scroll view.
    /// We also defer the selection / mouse pans for the same reason.
    private func deferSwiftTermPansToCanvas(in vc: TerminalContainerVC) {
        let canvasPan = scrollView.panGestureRecognizer
        let canvasPinch = scrollView.pinchGestureRecognizer
        let tv = vc.terminalView!
        // Built-in UIScrollView pan + pinch on TerminalView itself.
        tv.panGestureRecognizer.require(toFail: canvasPan)
        if let pinch = canvasPinch { tv.panGestureRecognizer.require(toFail: pinch) }
        if let tvPinch = tv.pinchGestureRecognizer {
            tvPinch.require(toFail: canvasPan)
            if let pinch = canvasPinch { tvPinch.require(toFail: pinch) }
        }
        // Any other pans SwiftTerm attaches (selection, mouse panning).
        for gr in tv.gestureRecognizers ?? [] {
            guard let pan = gr as? UIPanGestureRecognizer else { continue }
            if pan === tv.panGestureRecognizer { continue }
            pan.require(toFail: canvasPan)
            if let pinch = canvasPinch { pan.require(toFail: pinch) }
        }
    }

    /// Build the per-pane action menu. Focus lives here because the title bar
    /// no longer has a dedicated focus button — it traded that slot for the
    /// voice button. Uses a deferred element so "Focus" ↔ "Exit Focus" stays
    /// in sync with the current zoom state each time the menu opens.
    private func makePaneMenu(for paneID: TmuxPaneID) -> UIMenu {
        let focusElement = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            let isFocused = (self.focusedPaneID == paneID)
            let action = UIAction(
                title: isFocused ? "Exit Focus" : "Focus Pane",
                image: UIImage(systemName: isFocused
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
            ) { [weak self] _ in
                guard let self else { return }
                if self.focusedPaneID != nil { self.exitFocusMode() }
                else { self.enterFocusMode(paneID: paneID) }
            }
            completion([action])
        }

        return UIMenu(children: [
            focusElement,
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
    }

    // MARK: - Layout

    private var cellSize: CGSize {
        let font = UIFont.monospacedSystemFont(ofSize: STTheme.terminalFontSize, weight: .regular)
        let sample = NSString(string: "M")
        let size = sample.size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Cache last tmux client size sent over .refreshClient so we don't spam
    /// the control channel on every layoutPanes (which can fire from
    /// viewDidLayoutSubviews, safe area changes, etc.).
    private var lastTmuxClientSize: (cols: Int, rows: Int)?

    /// Computes the area available for terminal content — full view bounds
    /// minus the home indicator bottom safe area and any on-screen keyboard.
    private var availableContentSize: CGSize {
        let bottomSafe = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        let reserve = max(keyboardInsetBottom, bottomSafe)
        return CGSize(
            width: view.bounds.width,
            height: max(0, view.bounds.height - reserve)
        )
    }

    /// Whether tmux mode should treat the visible area as a single "non-tmux
    /// equivalent" pane: either there's only one pane in the session, or the
    /// user has zoomed/focused a pane. In both cases we render that pane at
    /// 1:1 cell scale, filling the viewport, and resize the tmux client
    /// viewport to match — so SIGWINCH reaches the remote shell exactly the
    /// way it would for a non-tmux shell.
    private var shouldRenderAsSinglePane: Bool {
        guard let viewModel else { return false }
        if focusedPaneID != nil { return true }
        return viewModel.paneViewModels.count == 1
    }

    /// Toggle canvas pan + pinch based on whether we're in a mode where the
    /// pane fills the viewport at 1:1 (non-tmux single pane, tmux single
    /// pane, or focus mode). In those modes there's nothing to pan/zoom —
    /// gestures should pass through to SwiftTerm (scroll history, selection).
    private func setCanvasGesturesEnabled(_ enabled: Bool) {
        guard canvasInteractionEnabled else {
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.pinchGestureRecognizer?.isEnabled = false
            return
        }
        scrollView.panGestureRecognizer.isEnabled = enabled
        scrollView.pinchGestureRecognizer?.isEnabled = enabled
    }

    private func layoutPanes() {
        // Non-tmux single pane: fill the view minus safe area + keyboard.
        // SwiftTerm picks up the new size, fires sizeChanged, and the PTY
        // SIGWINCHes via SSHService.resize. The pane's titleBar sits at the
        // bottom of `single.view`, so quick keys / voice button end up flush
        // above the keyboard.
        if let single = singlePaneVC {
            let size = availableContentSize
            canvasView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
            scrollView.contentInset = .zero
            single.view.frame = CGRect(origin: .zero, size: size)
            gestureCoordinator.updateOverlayFrame(CGRect(origin: .zero, size: size))
            setCanvasGesturesEnabled(false)
            return
        }

        guard let viewModel else { return }
        let panes = viewModel.paneViewModels.map(\.pane)
        guard !panes.isEmpty else { return }

        // Tmux: single-pane session OR focus mode → behave like non-tmux.
        // Resize the tmux client to fit the available area; the pane fills
        // the viewport at native 1:1 cell scale; other panes (if any) are
        // hidden. SIGWINCH propagates to the remote shell, same as non-tmux.
        if shouldRenderAsSinglePane {
            let size = availableContentSize
            let cell = cellSize
            let cols = max(20, Int(size.width / cell.width))
            let rows = max(5, Int(size.height / cell.height))

            canvasView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
            scrollView.contentInset = .zero
            scrollView.zoomScale = 1.0

            let targetID = focusedPaneID ?? panes[0].id
            for (paneID, vc) in paneControllers {
                if paneID == targetID {
                    vc.view.frame = CGRect(origin: .zero, size: size)
                    vc.view.isHidden = false
                    vc.view.layer.borderWidth = 0
                } else {
                    vc.view.isHidden = true
                }
            }
            gestureCoordinator.updateOverlayFrame(CGRect(origin: .zero, size: size))

            // Push the new viewport to tmux server (debounced via last-sent).
            if lastTmuxClientSize?.cols != cols || lastTmuxClientSize?.rows != rows {
                lastTmuxClientSize = (cols, rows)
                viewModel.resizeTmuxClient(cols: cols, rows: rows)
            }
            setCanvasGesturesEnabled(false)
            return
        }

        // Multi-pane tmux mode: cell-grid layout. Canvas size = full tmux grid;
        // scrollView handles overflow. We deliberately do NOT resize the tmux
        // client here — the user's chosen split layout is authoritative, and
        // mid-session SIGWINCH on every keyboard event would flicker every
        // pane. Keyboard handling for this mode lives in applyKeyboardInset.
        lastTmuxClientSize = nil  // reset cache so re-entering single mode re-sends
        setCanvasGesturesEnabled(true)
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
            vc.view.isHidden = false
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

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        layoutPanes()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            if self.shouldRenderAsSinglePane {
                self.layoutPanes()
            } else {
                self.fitToScreen(animated: false)
            }
        })
    }
}
