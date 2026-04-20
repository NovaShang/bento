import SwiftUI

/// Bridges the UIKit terminal views into SwiftUI navigation.
/// Supports both single-pane (non-tmux) and multi-pane (tmux) modes.
struct TerminalWrapperView: View {
    let host: Host
    let onDismiss: () -> Void

    @StateObject private var viewModel: TerminalViewModel
    @EnvironmentObject private var hostStore: HostStore

    init(host: Host, onDismiss: @escaping () -> Void) {
        self.host = host
        self.onDismiss = onDismiss
        _viewModel = StateObject(wrappedValue: TerminalViewModel(host: host))
    }

    var body: some View {
        ZStack(alignment: .top) {
            if viewModel.isTmuxReady {
                MultiPaneView(viewModel: viewModel)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                SinglePaneView(viewModel: viewModel)
                    .ignoresSafeArea(.container, edges: .bottom)
            }

            topBar
        }
        .statusBarHidden(true)
        .onAppear {
            hostStore.markConnected(host)
        }
        .onDisappear {
            viewModel.disconnect()
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

/// UIKit container that manages multiple TerminalContainerVC instances
final class MultiPaneContainerVC: UIViewController {
    var viewModel: TerminalViewModel?
    private var paneControllers: [TmuxPaneID: TerminalContainerVC] = [:]

    func setupPanes() {
        guard let viewModel else { return }
        for paneVM in viewModel.paneViewModels {
            addPaneController(for: paneVM)
        }
        layoutPanes()
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

        // Update active state visuals
        for paneVM in viewModel.paneViewModels {
            if let vc = paneControllers[paneVM.paneID] {
                vc.view.layer.borderWidth = paneVM.isActive ? 2 : 0.5
                vc.view.layer.borderColor = paneVM.isActive
                    ? UIColor.systemBlue.cgColor
                    : UIColor.systemGray.withAlphaComponent(0.3).cgColor
            }
        }

        layoutPanes()
    }

    private func addPaneController(for paneVM: PaneViewModel) {
        let vc = TerminalContainerVC()
        vc.bindToPaneVM(paneVM)

        addChild(vc)
        view.addSubview(vc.view)
        vc.didMove(toParent: self)

        // Tap to select pane
        let tap = UITapGestureRecognizer(target: self, action: #selector(paneTapped(_:)))
        vc.view.addGestureRecognizer(tap)
        vc.view.tag = paneVM.paneID.raw

        vc.view.layer.cornerRadius = 4
        vc.view.clipsToBounds = true

        paneControllers[paneVM.paneID] = vc
    }

    @objc private func paneTapped(_ gesture: UITapGestureRecognizer) {
        guard let tappedView = gesture.view else { return }
        let paneID = TmuxPaneID(tappedView.tag)
        viewModel?.selectPane(paneID)
        updatePanes()
    }

    /// Character cell size based on the terminal font
    private var cellSize: CGSize {
        let fontSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 14 : 12
        let font = UIFont(name: "Menlo", size: fontSize)
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Measure a single character to get cell dimensions
        let sample = NSString(string: "M")
        let size = sample.size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func layoutPanes() {
        guard let viewModel else { return }

        let panes = viewModel.paneViewModels.map(\.pane)
        guard !panes.isEmpty else { return }

        let cell = cellSize
        let topInset: CGFloat = 44

        // Canvas size = tmux window size in pixels
        // Each pane is positioned at its tmux coordinates * cell size
        for paneVM in viewModel.paneViewModels {
            guard let vc = paneControllers[paneVM.paneID] else { continue }
            let p = paneVM.pane

            let frame = CGRect(
                x: CGFloat(p.x) * cell.width,
                y: topInset + CGFloat(p.y) * cell.height,
                width: CGFloat(p.width) * cell.width,
                height: CGFloat(p.height) * cell.height
            )
            vc.view.frame = frame.insetBy(dx: 1, dy: 1)
        }

        // Set content size for future scroll/zoom (Phase 3)
        let maxRight = panes.map { $0.x + $0.width }.max() ?? 80
        let maxBottom = panes.map { $0.y + $0.height }.max() ?? 24
        let canvasSize = CGSize(
            width: CGFloat(maxRight) * cell.width,
            height: topInset + CGFloat(maxBottom) * cell.height
        )
        view.bounds.size = view.bounds.size // no-op for now, canvas zoom in Phase 3
        _ = canvasSize // will be used for scroll view content size
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
    }
}
