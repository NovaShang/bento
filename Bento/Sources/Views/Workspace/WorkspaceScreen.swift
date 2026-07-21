import SwiftUI
import Combine
import BentoTerminalCore

/// The session screen: bridges the UIKit pane views into SwiftUI navigation.
/// The WorkspaceViewModel and VoiceInputController are owned by the parent
/// (HostSessionsView) and passed in — the session has already been picked
/// before this view is pushed.
struct WorkspaceScreen: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var voiceController: VoiceInputController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSettings = false
    @State private var showOnboarding: Bool = GestureOnboardingOverlay.shouldShow
    /// One-shot notices driven by TipCenter: a transient toast plus the
    /// anchored teaching cards. Nil / false when nothing to say.
    @State private var tipToast: String?
    @State private var showStateLegend = false
    @State private var showParallelTip = false
    @State private var showVoiceAdvancedTip = false
    @State private var showQwenSuggestion = false
    @State private var parallelTipTask: Task<Void, Never>?
    @ObservedObject private var tips = TipCenter.shared
    @State private var showSplitSheet = false
    @State private var pendingClosePane: PaneID?
    /// Kill Session is destructive AND irreversible (every pane dies), so
    /// it goes through a confirmation before it runs.
    @State private var pendingKillSession = false
    /// The active pane awaiting a "Move to New Session" name prompt (from the
    /// ⋯ menu's pane section), plus the typed name.
    @State private var pendingMovePane: PaneID?
    @State private var moveToSessionName = ""
    /// One-shot latch for the phone's Focus-by-default.
    @State private var focusDefaultApplied = false

    private var host: Host { viewModel.host }

    /// iPad (regular width) shows List mode as a leading pane sidebar; the
    /// phone (compact width) uses the bottom pane tab bar instead.
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    /// Bottom pane tab bar: List mode's switcher on compact-width devices.
    private var showsPaneTabs: Bool {
        viewModel.isSessionReady && viewModel.sessionMode == .list && !isRegularWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            if showsPaneTabs {
                PaneTabBar(viewModel: viewModel)
            }
        }
        // Without the tab bar the panes reclaim the home-indicator strip.
        // With the bar, the VStack respects the bottom inset and the bar owns
        // it. The keyboard is ignored either way — each chat pane does its
        // own keyboard avoidance (shrinks its transcript, lifts its composer).
        .ignoresSafeArea(.container, edges: showsPaneTabs ? [] : .bottom)
        .ignoresSafeArea(.keyboard)
        .overlay { voiceOverlay }
        // The voice "AI correct" preview: an inline bar riding the keyboard's
        // top edge (NOT a modal — the panes stay visible while composing).
        .overlay(alignment: .bottom) {
            if voiceController.showPreview {
                ComposeBar(controller: voiceController)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: voiceController.showPreview)
        .overlay { onboardingOverlay }
        .overlay(alignment: .top) { tipToastView }
        .overlay { stateLegendOverlay }
        .overlay(alignment: .top) { parallelTipCard }
        .overlay(alignment: .bottom) { voiceAdvancedTipCard }
        .sheet(isPresented: $showSettings) { SettingsView() }
        // Standard system navigation bar: back + session-switcher on the
        // left, the mode switch centered, the ⋯ menu on the right.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: backTapped) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Sessions")
            }
            ToolbarItem(placement: .topBarLeading) {
                sessionTitle
            }
            ToolbarItem(placement: .principal) {
                if viewModel.isSessionReady { modeToggle }
            }
            ToolbarItem(placement: .topBarTrailing) {
                sessionMenu
            }
        }
        .sheet(isPresented: $showSplitSheet) {
            NewPaneSheet(title: "Split — Path & Command") { path, command in
                Task { await viewModel.splitPane(horizontal: true, seed: .custom(path: path, command: command)) }
            }
        }
        .alert(closePaneAlertTitle, isPresented: Binding(
            get: { pendingClosePane != nil },
            set: { if !$0 { pendingClosePane = nil } }
        )) {
            Button("Close Pane", role: .destructive) {
                if let id = pendingClosePane { viewModel.closePane(id) }
                pendingClosePane = nil
            }
            Button("Cancel", role: .cancel) { pendingClosePane = nil }
        } message: {
            Text("The agent running in it will be terminated.")
        }
        .alert("Kill this session?", isPresented: $pendingKillSession) {
            Button("Kill Session", role: .destructive) {
                viewModel.killSession()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every pane in this session is closed and its processes are terminated. This can't be undone.")
        }
        .onChange(of: viewModel.isSessionReady) { _, ready in
            if ready {
                applyPhoneFocusDefault()
                // Populate the session switcher once attached.
                Task { await viewModel.refreshSessions() }
            }
        }
        .onAppear { if viewModel.isSessionReady { applyPhoneFocusDefault() } }
        // ---- One-shot teaching moments. Each fires at the user's FIRST
        // encounter with the concept, once per install. ----
        .onChange(of: viewModel.agentsWaiting) { _, waiting in
            // The first amber pane is the first time the app "needs" the
            // user: the moment the color legend lands.
            if waiting > 0, tips.shouldShow(.stateLegend) {
                withAnimation { showStateLegend = true }
            }
        }
        .onChange(of: viewModel.agentsWorking) { _, working in
            handleWorkingChange(working)
        }
        .onChange(of: showsPaneTabs) { _, shown in
            if shown, tips.consume(.paneTabsIntro) {
                showTipToast("One agent per screen — switch with the tabs below. Each tab's dot is that agent's status.")
            }
        }
        .onChange(of: viewModel.sessionPanes.count) { _, _ in maybeShowSidebarIntro() }
        .onChange(of: viewModel.sessionMode) { _, _ in maybeShowSidebarIntro() }
        .onChange(of: voiceController.voiceSendTotal) { _, n in
            handleVoiceSendMilestone(n)
        }
        .alert("Better Chinese recognition?", isPresented: $showQwenSuggestion) {
            Button("Switch") {
                UserDefaults.standard.set("qwen", forKey: "speech_engine")
            }
            Button("Keep current", role: .cancel) {}
        } message: {
            Text("You seem to speak Chinese — the Qwen engine is much more accurate for 中文 and mixed 中英. Free, no setup, switch back anytime in Settings.")
        }
    }

    /// Phones open a multi-pane tiling in Focus by default — an act-and-inform
    /// default instead of a prompt. The toggle is lossless and one tap away
    /// from reversal, which is what makes the silent default safe.
    private func applyPhoneFocusDefault() {
        guard !focusDefaultApplied else { return }
        focusDefaultApplied = true
        guard UIDevice.current.userInterfaceIdiom == .phone,
              viewModel.isSessionReady,
              viewModel.paneViewModels.count > 1,
              !UserDefaults.standard.bool(forKey: "listModePrompt.\(viewModel.activeSessionName ?? "")")
        else { return }
        UserDefaults.standard.set(true, forKey: "listModePrompt.\(viewModel.activeSessionName ?? "")")
        viewModel.setMode(.list)
        if tips.consume(.focusAutoSwitch) {
            showTipToast("Opened in Focus — one agent per screen. Parallel ⇄ Focus up top switches views; nothing is lost.")
        }
    }

    /// Show a transient, non-blocking teaching toast (auto-hides).
    private func showTipToast(_ text: String) {
        withAnimation { tipToast = text }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { if tipToast == text { tipToast = nil } }
        }
    }

    /// The parallel curriculum, driven by the working-agent count.
    private func handleWorkingChange(_ working: Int) {
        // Both boxes busy at once → the payoff line.
        if working >= 2, tips.consume(.parallelBothWorking) {
            showTipToast("This is parallel — every box works at once. Whoever needs you changes color.")
        }
        // The first solo agent has been working 10s (the user is idle,
        // watching) → suggest opening a second one.
        guard tips.shouldShow(.parallelSecondAgent) else { return }
        parallelTipTask?.cancel()
        guard working >= 1, viewModel.paneViewModels.count == 1 else { return }
        parallelTipTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled,
                  viewModel.agentsWorking >= 1,
                  tips.consume(.parallelSecondAgent) else { return }
            withAnimation { showParallelTip = true }
        }
    }

    /// iPad sidebar introduction, first time it appears with real content
    /// (≥ 2 panes in List mode on a regular-width screen).
    private func maybeShowSidebarIntro() {
        guard viewModel.sessionPanes.count >= 2,
              viewModel.sessionMode == .list,
              isRegularWidth,
              tips.consume(.sidebarIntro) else { return }
        showTipToast("Every pane is one agent — tap to switch. The icons show who's working and who needs you.")
    }

    /// Voice-send milestones. The advanced gestures wait for the 3rd send
    /// (muscle memory first); the Chinese-engine suggestion lands right
    /// after the 1st send, while the experience is fresh.
    private func handleVoiceSendMilestone(_ n: Int) {
        guard n > 0 else { return }
        if n >= 1,
           Locale.preferredLanguages.first?.hasPrefix("zh") == true,
           (UserDefaults.standard.string(forKey: "speech_engine") ?? "apple") == "apple",
           tips.consume(.qwenSuggestion) {
            showQwenSuggestion = true
        }
        if n >= 3, tips.shouldShow(.voiceAdvanced) {
            tips.markShown(.voiceAdvanced)
            withAnimation { showVoiceAdvancedTip = true }
        }
    }

    /// Pane content. Tiled: the tiles (or a zoomed pane) fill the page.
    /// List: the focused pane shows directly; iPad (regular width) adds the
    /// shared pane sidebar on the left, the phone uses the bottom tab bar.
    @ViewBuilder
    private var content: some View {
        if viewModel.isSessionReady, viewModel.sessionMode == .list, isRegularWidth {
            HStack(spacing: 0) {
                PaneSidebar(viewModel: viewModel)
                    .frame(width: 260)
                Divider()
                paneGrid
            }
        } else {
            paneGrid
        }
    }

    private var paneGrid: some View {
        PaneGridView(viewModel: viewModel, voiceController: voiceController)
        // Move-to-new-session name prompt for the ⋯ menu's Pane section.
        // Hosted here (not on `body`) to keep the body's modifier chain
        // type-checkable.
        .alert("Move to New Session", isPresented: Binding(
            get: { pendingMovePane != nil },
            set: { if !$0 { pendingMovePane = nil } }
        )) {
            TextField("Session name", text: $moveToSessionName)
            Button("Move") {
                if let id = pendingMovePane { movePane(id, toSessionNamed: moveToSessionName) }
                pendingMovePane = nil
            }
            Button("Cancel", role: .cancel) { pendingMovePane = nil }
        } message: {
            Text("The pane keeps running — it moves to the new session.")
        }
    }

    /// ⋯ menu → Move to Session: kick the async move on the view model. The
    /// pane keeps running; it lands as a pane of the target session.
    private func movePane(_ id: PaneID, toSessionNamed name: String) {
        guard !name.isEmpty else { return }
        Task { _ = await viewModel.movePane(id, toSession: name) }
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
        if showOnboarding, viewModel.isSessionReady {
            GestureOnboardingOverlay {
                GestureOnboardingOverlay.markDismissed()
                withAnimation { showOnboarding = false }
            }
            .transition(.opacity)
        }
    }

    // MARK: - Teaching overlays (TipCenter)

    /// Transient top toast for fire-and-forget lessons.
    @ViewBuilder
    private var tipToastView: some View {
        if let text = tipToast {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoEmerald)
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.bentoInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.bentoSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { withAnimation { tipToast = nil } }
        }
    }

    /// The 4-color state legend — the product's mental-model key, presented
    /// the first time any pane turns amber. Non-modal.
    @ViewBuilder
    private var stateLegendOverlay: some View {
        if showStateLegend {
            StateLegendCard {
                tips.markShown(.stateLegend)
                withAnimation { showStateLegend = false }
            }
            .padding(.horizontal, 24)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    /// "Open a second agent" nudge, anchored under the top bar near the menus
    /// that can actually do it.
    @ViewBuilder
    private var parallelTipCard: some View {
        if showParallelTip {
            VStack(alignment: .leading, spacing: 8) {
                Text("It's working — you don't have to wait.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                Text(viewModel.sessionMode == .list
                     ? "Open a second agent: tap + in the pane list."
                     : "Open a second agent: ⋯ menu → Split.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoInkDim)
                Button("Got it") { withAnimation { showParallelTip = false } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.bentoEmerald)
            }
            .padding(14)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.bentoSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1)
            )
            .padding(.top, 52)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Advanced voice gestures, taught after the 3rd successful send.
    @ViewBuilder
    private var voiceAdvancedTipCard: some View {
        if showVoiceAdvancedTip {
            VStack(alignment: .leading, spacing: 8) {
                Text("Voice, level 2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                Label {
                    Text("Slide **right** while holding: review & edit the text before it sends.")
                        .font(.system(size: 13)).foregroundStyle(Color.bentoInkDim)
                } icon: {
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.bentoEmerald)
                }
                Label {
                    Text("Slide **up**: send immediately on release.")
                        .font(.system(size: 13)).foregroundStyle(Color.bentoInkDim)
                } icon: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.bentoEmerald)
                }
                Button("Got it") { withAnimation { showVoiceAdvancedTip = false } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.bentoEmerald)
            }
            .padding(14)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.bentoSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1)
            )
            .padding(.bottom, 90)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Top Bar

    /// Session name (primary) + host (subtitle). Tapping the name is a quick
    /// session switcher — a menu of the host's workspace sessions, switch in
    /// place. Plain (non-tappable) text before a session is attached.
    @ViewBuilder
    private var sessionTitle: some View {
        let label = VStack(spacing: 1) {
            Text(viewModel.activeSessionName ?? host.displayName)
                .font(.headline).lineLimit(1)
            Text(host.displayName).lineLimit(1)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if viewModel.isSessionReady {
            Menu {
                ForEach(viewModel.availableSessions, id: \.self) { name in
                    Button { viewModel.switchSession(name) } label: {
                        if name == viewModel.activeSessionName {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Divider()
                Button { Task { await viewModel.refreshSessions() } } label: {
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

    /// Parallel | Focus segmented control — a pure view-preference toggle,
    /// lossless in both directions.
    private var modeToggle: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.sessionMode },
            set: { newMode in
                // First interaction retires the intro dot.
                if tips.shouldShow(.modeToggleIntro) {
                    tips.markShown(.modeToggleIntro)
                }
                guard newMode != viewModel.sessionMode else { return }
                // Leaving a focused (zoomed) pane before switching keeps the
                // result visible.
                if let z = viewModel.zoomedPaneID {
                    viewModel.toggleZoom(z)
                }
                viewModel.setMode(newMode)
            }
        )) {
            Text("Parallel").tag(SessionViewMode.tiled)
            Text("Focus").tag(SessionViewMode.list)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        // Intro dot: "two views, switch freely, nothing is lost" — a quiet
        // affordance marker. Cleared on first use.
        .overlay(alignment: .topTrailing) {
            if tips.shouldShow(.modeToggleIntro) {
                Circle()
                    .fill(Color.bentoEmerald)
                    .frame(width: 7, height: 7)
                    .offset(x: 3, y: -3)
            }
        }
    }

    /// Overflow menu — a native SwiftUI `Menu`, kept short so it never
    /// recomputes-and-resets while open.
    private var sessionMenu: some View {
        Menu {
            if viewModel.isSessionReady {
                splitSection
            }
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gear")
            }
            if viewModel.isSessionReady {
                panesSection
                Button(role: .destructive) { pendingKillSession = true } label: {
                    Label("Kill Session", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
        }
    }

    /// Split section — Tiled only (List mode creates via the tab bar /
    /// sidebar "+"). The two seeded entries mirror List's pane creation.
    @ViewBuilder
    private var splitSection: some View {
        if viewModel.sessionMode == .tiled {
            Section("Split") {
                Button(action: { viewModel.splitPane(horizontal: true) }) {
                    Label("Split Horizontal", systemImage: "rectangle.split.2x1")
                }
                Button(action: { viewModel.splitPane(horizontal: false) }) {
                    Label("Split Vertical", systemImage: "rectangle.split.1x2")
                }
                Button(action: { Task { await viewModel.splitPane(horizontal: true, seed: .duplicateCurrent) } }) {
                    Label("Split — Duplicate Current", systemImage: "plus.square.on.square")
                }
                Button(action: { showSplitSheet = true }) {
                    Label("Split — Path & Command…", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    /// Active-pane actions, scoped to the ONE active pane (never a live list
    /// of all panes), so the menu stays short.
    @ViewBuilder
    private var panesSection: some View {
        if let activeID = viewModel.activePaneID {
            Section("Pane") {
                // Zoom is a Parallel-mode concept — Focus already shows one
                // pane full-screen.
                if viewModel.sessionMode == .tiled {
                    if let zoomed = viewModel.zoomedPaneID {
                        Button {
                            viewModel.toggleZoom(zoomed)
                        } label: {
                            Label("Restore Pane", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    } else {
                        Button {
                            viewModel.toggleZoom(activeID)
                        } label: {
                            Label("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                }
                PaneMoveToSessionMenu(viewModel: viewModel) { session in
                    movePane(activeID, toSessionNamed: session)
                } onNewSession: {
                    moveToSessionName = ""
                    pendingMovePane = activeID
                }
                Button(role: .destructive) {
                    pendingClosePane = activeID
                } label: {
                    Label("Close Pane", systemImage: "xmark")
                }
            }
        }
    }

    private var closePaneAlertTitle: String {
        let name = pendingClosePane.map { viewModel.paneDisplayName($0) } ?? ""
        return "Close “\(name)”?"
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

// MARK: - Pane grid bridge

/// SwiftUI bridge for the UIKit container that hosts the live panes (tiled,
/// or one focused).
struct PaneGridView: UIViewControllerRepresentable {
    @ObservedObject var viewModel: WorkspaceViewModel
    /// Deliberately NOT @ObservedObject: only read in makeUIViewController.
    /// Observing it re-ran updateUIViewController (→ refreshPanes → a full
    /// layout pass) on every keystroke/touch the controller published.
    let voiceController: VoiceInputController

    func makeUIViewController(context: Context) -> PaneContainerVC {
        let vc = PaneContainerVC()
        vc.viewModel = viewModel
        vc.voiceController = voiceController
        vc.refreshPanes()
        return vc
    }

    static func dismantleUIViewController(_ vc: PaneContainerVC, coordinator: ()) {
        vc.teardownAll()
    }

    func updateUIViewController(_ vc: PaneContainerVC, context: Context) {
        vc.refreshPanes()
    }
}

// MARK: - Pane container

/// Hosts the live panes. Two layouts:
///   - **Tiles**: every workspace pane shown at once, positioned
///     proportionally by its layout-tree cell geometry. Tap = select-pane.
///   - **Focus**: a single pane (active or zoomed) fills the viewport.
final class PaneContainerVC: UIViewController {
    var viewModel: WorkspaceViewModel? {
        didSet { wireGeometryHook() }
    }
    var voiceController: VoiceInputController?

    /// Re-tile SYNCHRONOUSLY when new pane geometry is applied, so pane
    /// views resize in the same main-actor turn as the store mutation.
    private func wireGeometryHook() {
        viewModel?.onGeometryApplied = { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    /// Pane chat controllers, one per pane.
    private(set) var paneControllers: [PaneID: AgentChatVC] = [:]

    /// Holds the pane VCs; always exactly the viewport.
    private let contentView = UIView()

    /// The translucent landing preview shown while a title-bar drag hovers a
    /// target pane; created on the first hover of a drag, torn down when the
    /// drag ends. Mirrors the macOS host's PaneDropZoneOverlay.
    private var dropOverlay: PaneDropZoneOverlayView?

    /// Transparent overlay over the panes that claims touches only on a
    /// divider between adjacent panes, to drag-resize them. Mirrors the
    /// macOS `DividerOverlay`.
    private let dividerOverlay = TileDividerOverlay()

    // MARK: - Lifecycle

    /// The panes run to the bottom edge, so let the home indicator auto-dim.
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(activePaneAppearanceChanged),
            name: .terminalThemeChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Tear down every pane before this container is released.
    func teardownAll() {
        for vc in paneControllers.values { vc.teardown() }
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

    /// The keyboard / voice target VC: zoomed pane, else active.
    private var focusedOrActiveVC: AgentChatVC? {
        if let id = viewModel?.zoomedPaneID, let vc = paneControllers[id] { return vc }
        if let id = viewModel?.activePaneID, let vc = paneControllers[id] { return vc }
        return paneControllers.values.first
    }

    // MARK: - Pane reconciliation

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
        view.setNeedsLayout()
    }

    private func addPaneController(for paneVM: PaneViewModel) {
        guard let viewModel else { return }
        let paneID = paneVM.paneID
        let vc = AgentChatVC(store: viewModel.workspace)
        vc.voiceController = voiceController
        vc.bindToPaneVM(paneVM)
        vc.onSelectPaneTapped = { [weak self] in
            self?.viewModel?.selectPane(paneID)
            self?.view.setNeedsLayout()
        }
        vc.onTitleDrag = { [weak self] phase in
            self?.handleTitleSwap(source: paneID, phase: phase)
        }
        addChild(vc)
        contentView.addSubview(vc.view)
        vc.didMove(toParent: self)
        paneControllers[paneID] = vc
    }

    // MARK: - Layout

    /// Whether we're showing a single full pane (Focus mode, zoomed, or a
    /// lone pane).
    private var isFocusLayout: Bool {
        viewModel?.zoomedPaneID != nil
            || (viewModel?.paneViewModels.count ?? 0) <= 1
            || viewModel?.sessionMode == .list
    }

    private var effectiveFocusID: PaneID? {
        if let z = viewModel?.zoomedPaneID { return z }
        if (viewModel?.paneViewModels.count ?? 0) == 1 { return viewModel?.paneViewModels.first?.paneID }
        return viewModel?.activePaneID
    }

    /// The area the panes map to. Respect the LEFT/RIGHT safe-area insets
    /// (landscape notch).
    private var pageRect: CGRect {
        let insets = view.safeAreaInsets
        return CGRect(x: insets.left, y: 0,
                      width: max(0, view.bounds.width - insets.left - insets.right),
                      height: view.bounds.height)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout() })
    }

    private func layoutPanes() {
        dividerOverlay.dividers = []
        guard let viewModel, !paneControllers.isEmpty else { return }
        let rect = pageRect
        contentView.frame = rect

        if isFocusLayout, let focusID = effectiveFocusID {
            layoutFocus(focusID, page: rect.size)
        } else {
            layoutTiles(viewModel.paneViewModels, page: rect.size)
        }
        syncBackgroundToActivePane()
    }

    /// Single pane fills the page; the rest are hidden.
    private func layoutFocus(_ focusID: PaneID, page: CGSize) {
        for (id, vc) in paneControllers {
            let isFocus = (id == focusID)
            vc.view.isHidden = !isFocus
            if isFocus {
                vc.tiled = false
                vc.titleBarHeight = AgentChatVC.defaultTitleBarHeight
                vc.surfaceInsetX = 0
                vc.view.frame = CGRect(origin: .zero, size: page)
                vc.titleBar.isActivePane = true
                if let pvm = viewModel?.paneViewModels.first(where: { $0.paneID == focusID }) {
                    vc.updatePaneState(pvm.paneState, active: true)
                }
            }
        }
    }

    /// Horizontal inset between a pane's content and its container edge, so
    /// abutting tiles read as separate panes (matches the macOS host).
    private static let paneGutter: CGFloat = 3

    /// Tile all panes proportionally: each pane's frame is its layout-tree
    /// fraction (recovered from the legacy 160×48 projection) × the page.
    private func layoutTiles(_ panes: [PaneViewModel], page: CGSize) {
        let totalCols = CGFloat(max(panes.map { $0.pane.x + $0.pane.width }.max() ?? 1, 1))
        let totalRows = CGFloat(max(panes.map { $0.pane.y + $0.pane.height }.max() ?? 1, 1))
        let activeID = viewModel?.activePaneID
        for (id, vc) in paneControllers {
            guard let pvm = panes.first(where: { $0.paneID == id }) else { continue }
            let p = pvm.pane
            vc.view.isHidden = false
            vc.tiled = true
            vc.titleBarHeight = AgentChatVC.defaultTitleBarHeight
            vc.surfaceInsetX = Self.paneGutter
            vc.view.frame = CGRect(
                x: (CGFloat(p.x) / totalCols) * page.width,
                y: (CGFloat(p.y) / totalRows) * page.height,
                width: (CGFloat(p.width) / totalCols) * page.width,
                height: (CGFloat(p.height) / totalRows) * page.height)
            vc.updatePaneState(pvm.paneState, active: pvm.paneID == activeID)
        }
        // Refresh the drag-to-resize divider hot zones for the new geometry.
        // The synthetic per-cell size maps drag points back onto the legacy
        // 160×48 resize unit (one "cell" = 1/160 or 1/48 of the canvas), so
        // the divider tracks the finger 1:1.
        let synthPpc = CGSize(width: page.width / totalCols, height: page.height / totalRows)
        dividerOverlay.frame = CGRect(origin: .zero, size: page)
        dividerOverlay.pointsPerCell = CGPoint(x: synthPpc.width, y: synthPpc.height)
        dividerOverlay.dividers = computeTileDividers(page: page, ppc: synthPpc)
        contentView.bringSubviewToFront(dividerOverlay)
    }

    // MARK: - Divider resize

    /// Resize the boundary owned by `paneID` by a signed cell delta.
    /// Vertical divider → grow Right/shrink Left; horizontal → Down/Up.
    /// Identical mapping to the macOS host's `resizeBoundary`.
    private func resizeBoundary(paneID: PaneID, vertical: Bool, deltaCells: Int) {
        guard deltaCells != 0 else { return }
        let dir = vertical ? (deltaCells > 0 ? "R" : "L")
                           : (deltaCells > 0 ? "D" : "U")
        viewModel?.resizePaneBy(paneID, direction: dir, amount: abs(deltaCells))
    }

    /// Compute divider hot zones from the current pane frames, matching the
    /// macOS `computeDividers`. The vertical hot zone is centred on the
    /// line; the horizontal one sits just ABOVE it so it never covers the
    /// lower pane's title bar (the drag-to-swap handle).
    private func computeTileDividers(page: CGSize, ppc: CGSize) -> [TileDividerOverlay.Divider] {
        let frames: [(id: PaneID, frame: CGRect)] = paneControllers.compactMap { id, vc in
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

    // MARK: - Title-drag swap / dock
    //
    // VS Code-style drop zones, exactly like the macOS host: hovering a
    // target pane previews the landing — its middle 50%×50% highlights the
    // WHOLE pane (drop = swap the two panes), the four edge bands highlight
    // that HALF (drop = re-split the target along that axis and dock the
    // dragged pane on that side).

    /// The pane + drop zone under a window-coordinate point, excluding the
    /// dragged pane. Pane frames live in `contentView`, so convert in first.
    private func dropTarget(atWindowPoint p: CGPoint, excluding source: PaneID)
        -> (pane: PaneID, zone: PaneDropZone)? {
        let local = contentView.convert(p, from: nil)
        guard let (id, vc) = paneControllers.first(where: { id, vc in
            id != source && !vc.view.isHidden && vc.view.frame.contains(local)
        }) else { return nil }
        return (id, PaneDropZone.zone(at: local, in: vc.view.frame))
    }

    private func handleTitleSwap(source paneID: PaneID, phase: TitleDragPhase) {
        // Rearranging only makes sense between visible tiles.
        guard !isFocusLayout else { return }
        switch phase {
        case .began:
            paneControllers[paneID]?.view.alpha = 0.6
        case .moved(let p):
            updateDropOverlay(dropTarget(atWindowPoint: p, excluding: paneID))
        case .ended(let p):
            let drop = dropTarget(atWindowPoint: p, excluding: paneID)
            endTitleDrag(paneID)
            guard let (target, zone) = drop else { return }
            if let dock = zone.dock {
                viewModel?.movePane(paneID, splitting: target,
                                    horizontal: dock.horizontal, before: dock.before)
            } else {
                viewModel?.swapPanes(paneID, with: target)
            }
        case .cancelled:
            endTitleDrag(paneID)
        }
    }

    private func endTitleDrag(_ paneID: PaneID) {
        paneControllers[paneID]?.view.alpha = 1.0
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
    }

    /// Show/move/hide the landing preview. The frame animates between zones
    /// and across panes while visible; appearing (or reappearing after a
    /// gap) snaps into place so the preview never slides in from a stale
    /// spot.
    private func updateDropOverlay(_ drop: (pane: PaneID, zone: PaneDropZone)?) {
        guard let drop, let paneFrame = paneControllers[drop.pane]?.view.frame else {
            dropOverlay?.isHidden = true
            return
        }
        let overlay: PaneDropZoneOverlayView
        let appearing: Bool
        if let existing = dropOverlay {
            overlay = existing
            appearing = overlay.isHidden
        } else {
            overlay = PaneDropZoneOverlayView()
            contentView.addSubview(overlay)   // above every pane view
            dropOverlay = overlay
            appearing = true
        }
        let target = drop.zone.highlightRect(in: paneFrame)
        overlay.isHidden = false
        overlay.zone = drop.zone
        if appearing {
            overlay.frame = target
        } else {
            UIView.animate(withDuration: 0.12) { overlay.frame = target }
        }
    }
}

/// The translucent landing preview shown while a pane drag hovers a target:
/// the whole pane for a center/swap drop (with a ⇄ badge — the one zone whose
/// meaning isn't its own shape), the docked half for an edge drop. Colored by
/// the inherited tint (the app accent, same as the focused-pane border).
/// Non-interactive; the title-bar pan owns the touch anyway.
final class PaneDropZoneOverlayView: UIView {
    private let icon = UIImageView(image: UIImage(
        systemName: "rectangle.2.swap",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)))

    var zone: PaneDropZone = .center {
        didSet { icon.isHidden = (zone != .center) }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.borderWidth = 2
        layer.cornerRadius = 6
        addSubview(icon)
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The real tint arrives when the view joins the hierarchy.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyTint()
    }

    private func applyTint() {
        backgroundColor = tintColor.withAlphaComponent(0.22)
        layer.borderColor = tintColor.cgColor
        icon.tintColor = tintColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.sizeToFit()
        icon.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// MARK: - Pane Tab Bar (List mode, compact width)

/// Bottom tab strip for List mode on phones: one tab per pane, browser-tab
/// style, horizontally scrollable, with a trailing "+" that offers the two
/// creation seeds. Each tab shows the pane's LIVE display name and its state
/// dot. Tapping a tab is select-pane ONLY. Long-press a tab → Move / Close
/// (confirmed: processes die).
struct PaneTabBar: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var pendingClose: PaneID?
    @State private var showCustomSheet = false
    @State private var pendingMove: PaneID?
    @State private var moveSessionName = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.sessionPanes, id: \.id) { pane in
                        PaneTab(name: viewModel.paneDisplayName(pane.id),
                                  state: viewModel.paneState(pane.id),
                                  isActive: pane.id == viewModel.activePaneID)
                            .id(pane.id)
                            .onTapGesture { viewModel.selectPane(pane.id) }
                            .contextMenu {
                                PaneMoveToSessionMenu(viewModel: viewModel) { session in
                                    movePane(pane.id, to: session)
                                } onNewSession: {
                                    moveSessionName = ""
                                    pendingMove = pane.id
                                }
                                Button(role: .destructive) {
                                    pendingClose = pane.id
                                } label: {
                                    Label("Close Pane", systemImage: "xmark")
                                }
                            }
                    }
                    newPaneButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.activePaneID) { _, newID in
                // Keep the current tab in view (a switch can come from any
                // attached device, not just a tap here).
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .background(
            // The bar owns the bottom inset: paint under the home indicator.
            Color.bentoShell.ignoresSafeArea(.container, edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Color.bentoBorder).frame(height: 1)
        }
        .alert(closeAlertTitle, isPresented: Binding(
            get: { pendingClose != nil },
            set: { if !$0 { pendingClose = nil } }
        )) {
            Button("Close Pane", role: .destructive) {
                if let id = pendingClose { viewModel.closePane(id) }
                pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text("The agent running in it will be terminated.")
        }
        .sheet(isPresented: $showCustomSheet) {
            NewPaneSheet(title: "New Pane") { path, command in
                Task { await viewModel.newFocusPane(.custom(path: path, command: command)) }
            }
        }
        .alert("Move to New Session", isPresented: Binding(
            get: { pendingMove != nil },
            set: { if !$0 { pendingMove = nil } }
        )) {
            TextField("Session name", text: $moveSessionName)
            Button("Move") {
                if let id = pendingMove { movePane(id, to: moveSessionName) }
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: {
            Text("The pane keeps running — it moves to the new session.")
        }
    }

    private func movePane(_ id: PaneID, to session: String) {
        Task { _ = await viewModel.movePane(id, toSession: session) }
    }

    private var closeAlertTitle: String {
        let name = pendingClose.map { viewModel.paneDisplayName($0) } ?? ""
        return "Close “\(name)”?"
    }

    /// The two creation seeds — same pair as the iPad/macOS sidebar.
    private var newPaneButton: some View {
        Menu {
            Button {
                Task { await viewModel.newFocusPane(.duplicateCurrent) }
            } label: {
                Label("Duplicate Current", systemImage: "plus.square.on.square")
            }
            Button {
                showCustomSheet = true
            } label: {
                Label("Path & Command…", systemImage: "folder.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.bentoInkDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.bentoSurface))
                .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
    }
}

// MARK: - New pane / split "path + command" form

/// The "specify path + command" mini-sheet, shared by List's "+" menu and
/// Tiled's "Split — Path & Command…". Empty command = default agent; empty
/// path = inherit the current pane's directory.
struct NewPaneSheet: View {
    var title: String
    var onCreate: (String?, String?) -> Void

    @State private var path = ""
    @State private var command = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Working Directory") {
                    TextField("Empty = current directory", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Command") {
                    TextField("Empty = default agent", text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(path.isEmpty ? nil : path,
                                 command.isEmpty ? nil : command)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct PaneTab: View {
    var name: String
    var state: PaneState
    var isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(STTheme.dotColor(for: state)))
                .frame(width: 8, height: 8)
                .shadow(color: glowColor, radius: glowRadius)

            Text(name.isEmpty ? "pane" : name)
                .font(.footnote)
                .foregroundStyle(isActive ? Color.bentoInk : Color.bentoInkDim)
                .lineLimit(1)
                .frame(maxWidth: 140)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(isActive ? Color.bentoSurfaceHi : Color.bentoSurface))
        .overlay(
            Capsule().strokeBorder(isActive ? Color.bentoEmerald : Color.bentoBorder,
                                   lineWidth: isActive ? 1.5 : 1)
        )
        .contentShape(Capsule())
    }

    private var glowColor: Color {
        switch state {
        case .awaitingInput: return Color(STTheme.dotColor(for: state)).opacity(0.8)
        case .working: return Color(STTheme.dotColor(for: state)).opacity(0.6)
        case .idle: return .clear
        }
    }

    private var glowRadius: CGFloat {
        switch state {
        case .awaitingInput: return 3
        case .working: return 2.5
        case .idle: return 0
        }
    }
}

// MARK: - Divider overlay (drag to resize)

/// A transparent overlay over the tiled panes. It is touch-transparent except
/// within a few points of a divider between two adjacent panes, where it
/// claims the touch to drag-resize them. Everywhere else, touches fall
/// through to the panes. iOS mirror of the macOS `DividerOverlay`.
final class TileDividerOverlay: UIView {
    /// A draggable boundary: the pane that owns it, orientation, and hot rect.
    struct Divider {
        let paneID: PaneID
        let vertical: Bool    // true = vertical line, drags left/right
        let position: CGFloat // x (vertical) or y (horizontal), in points
        let hotRect: CGRect
    }

    /// Touch grab sizes. Vertical dividers are CENTRED on the line.
    /// Horizontal dividers STRADDLE it — generous above (the upper pane's
    /// free surface) but only a little below, so the band sits on the border
    /// yet barely covers the lower pane's title bar (the drag-to-swap handle).
    static let hotThicknessV: CGFloat = 34
    static let hotAboveLine: CGFloat = 26
    static let hotBelowLine: CGFloat = 6

    var dividers: [Divider] = [] { didSet { setNeedsDisplay() } }
    /// Points per layout cell, set by the host so drag distance → cell delta.
    var pointsPerCell: CGPoint?
    /// (paneID, vertical, signed incremental cell delta) during a live drag.
    var onResize: ((PaneID, Bool, Int) -> Void)?

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
        // The line being dragged tracks the finger (the relayout lags), drawn
        // in the accent colour so the drag is clearly visible.
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
