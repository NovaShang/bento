#if canImport(UIKit)
import SwiftUI
import Combine
import BentoFoundation
import BentoUI
import BentoWorkbench
import BentoVoiceKit
import BentoFilePreviewKit
import BentoLink

/// The session screen: bridges the UIKit pane views into SwiftUI navigation.
/// The WorkspaceViewModel and VoiceInputController are owned by the parent
/// (HostSessionsView) and passed in — the session has already been picked
/// before this view is pushed.
public struct WorkspaceScreen: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var voiceController: VoiceInputController

    public init(viewModel: WorkspaceViewModel, voiceController: VoiceInputController) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _voiceController = ObservedObject(wrappedValue: voiceController)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// File preview (tap a tool-card path / browse the Files tree). iPhone → a
    /// sheet, iPad → a trailing dock, matching the macOS preview dock.
    @StateObject private var previewPresenter = FilePreviewPresenter()
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
    /// iPad only: which split-view columns are up. Driven by the mode, never by
    /// the user (see `syncSidebarVisibility`).
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly

    private var host: Host { viewModel.host }

    /// iPad (regular width) shows List mode as a leading pane sidebar; the
    /// phone (compact width) uses the bottom pane tab bar instead.
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    /// Bottom pane tab bar: List mode's switcher on compact-width devices.
    private var showsPaneTabs: Bool {
        viewModel.isSessionReady && viewModel.workspaceMode == .list && !isRegularWidth
    }

    public var body: some View {
        // Split from `bodyCore` so the modifier chain type-checks in time:
        // cross-module (this view now lives in BentoShelliOS) the solver can't
        // digest the whole overlay/sheet/alert/onChange chain as one
        // expression. Two halves keeps it well under budget; behavior is
        // identical to the single chain.
        bodyCore
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
            .onChange(of: viewModel.workspaceMode) { _, _ in maybeShowSidebarIntro() }
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

    private var bodyCore: some View {
        chrome
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
        .filePreviewPanel(previewPresenter, isRegularWidth: isRegularWidth)
        .onAppear {
            // Root the tree at whichever pane is active when the panel opens.
            // The context is pane-kind-specific (ACP session cwd vs tmux pane
            // cwd), so it comes through the shell registry the app installs —
            // this generic screen never names a pane module.
            previewPresenter.treeContextProvider = { [weak viewModel] in
                guard let viewModel, let id = viewModel.activePaneID else { return nil }
                return ShellPaneRegistry.previewContextProvider?(viewModel.workspace, id)
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
        .alert("Kill this workspace?", isPresented: $pendingKillSession) {
            Button("Kill Workspace", role: .destructive) {
                viewModel.killSession()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every pane in this workspace is closed and its processes are terminated. This can't be undone.")
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
              !UserDefaults.standard.bool(forKey: "listModePrompt.\(viewModel.activeWorkspaceName ?? "")")
        else { return }
        UserDefaults.standard.set(true, forKey: "listModePrompt.\(viewModel.activeWorkspaceName ?? "")")
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
              viewModel.workspaceMode == .list,
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

    /// The workspace's chrome.
    ///
    /// iPad (regular width) uses the platform's split view, which is what makes
    /// the sidebar a full-height floating panel and gives EACH COLUMN its own
    /// toolbar — so the back button lands in the content region beside the
    /// sidebar rather than in a banner stretched over both (Files, Notes and
    /// Mail all read this way). The pushed navigation bar is hidden here for
    /// exactly that reason: one full-width bar above two columns was the thing
    /// that looked like a lid over the UI.
    ///
    /// The phone has no sidebar, so it keeps the plain pushed bar. The branch is
    /// on SIZE CLASS, not on mode — it never flips under a running workspace, so
    /// no pane is remounted by it.
    @ViewBuilder
    private var chrome: some View {
        if isRegularWidth {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                PaneSidebar(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                    // The sidebar is mode-driven, never user-toggled (the same
                    // rule the macOS window follows), so there's nothing for a
                    // toggle button to mean.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                workspaceDetail
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { syncSidebarVisibility() }
            .onChange(of: showsPaneSidebar) { _, _ in syncSidebarVisibility() }
        } else {
            workspaceDetail
        }
    }

    /// The panes plus (on the phone) the pane tab bar — the split view's detail
    /// column, and the whole screen on a phone. Owns the workspace toolbar.
    private var workspaceDetail: some View {
        VStack(spacing: 0) {
            paneGrid
            if showsPaneTabs {
                PaneTabBar(viewModel: viewModel)
            }
        }
        // Without the tab bar the panes reclaim the home-indicator strip.
        // With the bar, the VStack respects the bottom inset and the bar owns
        // it. The keyboard is ignored on `body` either way — each chat pane does
        // its own keyboard avoidance (shrinks its transcript, lifts its composer).
        .ignoresSafeArea(.container, edges: showsPaneTabs ? [] : .bottom)
        // The phone (compact width) is too narrow for a segmented mode control,
        // so: a standalone back button on the left, the session title centered
        // (plain, out of the back button's glass group), and the layout switch
        // tucked into the ⋯ menu — Parallel barely applies on a phone anyway.
        // The iPad keeps the roomier layout: title beside back, segmented mode
        // switch centered.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: backTapped) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Workspaces")
            }
            if isRegularWidth {
                ToolbarItem(placement: .topBarLeading) {
                    sessionTitle
                }
                ToolbarItem(placement: .principal) {
                    if viewModel.isSessionReady { modeToggle }
                }
            } else {
                ToolbarItem(placement: .principal) {
                    sessionTitle
                }
            }
            if viewModel.isSessionReady {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { previewPresenter.browseFiles() } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Files")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                sessionMenu
            }
        }
    }

    /// The sidebar is MODE-driven, never user-toggled (same rule as the macOS
    /// window): it exists exactly when Focus mode has a wide enough screen.
    private var showsPaneSidebar: Bool {
        viewModel.isSessionReady && viewModel.workspaceMode == .list && isRegularWidth
    }

    private func syncSidebarVisibility() {
        let want: NavigationSplitViewVisibility = showsPaneSidebar ? .all : .detailOnly
        guard sidebarVisibility != want else { return }
        withAnimation { sidebarVisibility = want }
    }

    private var paneGrid: some View {
        PaneGridView(viewModel: viewModel, voiceController: voiceController,
                     previewPresenter: previewPresenter)
        // Move-to-new-session name prompt for the ⋯ menu's Pane section.
        // Hosted here (not on `body`) to keep the body's modifier chain
        // type-checkable.
        .alert("Move to New Workspace", isPresented: Binding(
            get: { pendingMovePane != nil },
            set: { if !$0 { pendingMovePane = nil } }
        )) {
            TextField("Workspace name", text: $moveToSessionName)
            Button("Move") {
                if let id = pendingMovePane { movePane(id, toSessionNamed: moveToSessionName) }
                pendingMovePane = nil
            }
            Button("Cancel", role: .cancel) { pendingMovePane = nil }
        } message: {
            Text("The pane keeps running — it moves to the new workspace.")
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
                // Land the panel's INPUT zone (not its center) on the finger,
                // so release-with-no-drag starts on the safe "Insert" zone.
                .position(
                    x: voiceController.fingerScreenPosition.x,
                    y: voiceController.fingerScreenPosition.y
                        + VoiceOverlayView.centerOffsetFromPress
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
                Text(viewModel.workspaceMode == .list
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
            Text(viewModel.activeWorkspaceName ?? host.displayName)
                .font(.headline).lineLimit(1)
            Text(host.displayName).lineLimit(1)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if viewModel.isSessionReady {
            Menu {
                ForEach(viewModel.availableSessions, id: \.self) { name in
                    Button { viewModel.switchSession(name) } label: {
                        if name == viewModel.activeWorkspaceName {
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

    /// Parallel | Focus — a pure view-preference toggle, lossless in both
    /// directions. On the phone (compact width) it lives inside the ⋯ menu
    /// (`modeSection`); the iPad keeps this segmented nav-bar control.
    private func selectMode(_ newMode: WorkspaceViewMode) {
        // First interaction retires the intro marker.
        if tips.shouldShow(.modeToggleIntro) {
            tips.markShown(.modeToggleIntro)
        }
        guard newMode != viewModel.workspaceMode else { return }
        // Leaving a focused (zoomed) pane before switching keeps the result
        // visible.
        if let z = viewModel.zoomedPaneID {
            viewModel.toggleZoom(z)
        }
        viewModel.setMode(newMode)
    }

    /// iPad segmented control for the layout switch.
    private var modeToggle: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.workspaceMode },
            set: { selectMode($0) }
        )) {
            Text("Parallel").tag(WorkspaceViewMode.tiled)
            Text("Focus").tag(WorkspaceViewMode.list)
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
                if !isRegularWidth { modeSection }
                splitSection
            }
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gear")
            }
            if viewModel.isSessionReady {
                panesSection
                Button(role: .destructive) { pendingKillSession = true } label: {
                    Label("Kill Workspace", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
        }
    }

    /// Layout switch inside the ⋯ menu. An inline picker renders as a
    /// checkmark list — Focus first, since it's the phone default.
    private var modeSection: some View {
        Section("Layout") {
            Picker("Layout", selection: Binding(
                get: { viewModel.workspaceMode },
                set: { selectMode($0) }
            )) {
                Label("Focus", systemImage: "rectangle").tag(WorkspaceViewMode.list)
                Label("Parallel", systemImage: "square.split.2x2").tag(WorkspaceViewMode.tiled)
            }
            .pickerStyle(.inline)
        }
    }

    /// Split section — Tiled only (List mode creates via the tab bar /
    /// sidebar "+"). The two seeded entries mirror List's pane creation.
    @ViewBuilder
    private var splitSection: some View {
        if viewModel.workspaceMode == .tiled {
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
                if viewModel.workspaceMode == .tiled {
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
/// or one focused). It sits in the split view's detail column on iPad and is
/// the whole screen on a phone — either way it is created ONCE, so switching
/// Parallel ⇄ Focus never tears a pane down.
struct PaneGridView: UIViewControllerRepresentable {
    @ObservedObject var viewModel: WorkspaceViewModel
    /// Deliberately NOT @ObservedObject: only read in makeUIViewController.
    /// Observing it re-ran updateUIViewController (→ refreshPanes → a full
    /// layout pass) on every keystroke/touch the controller published.
    let voiceController: VoiceInputController
    let previewPresenter: FilePreviewPresenter

    func makeUIViewController(context: Context) -> PaneContainerVC {
        let vc = PaneContainerVC()
        vc.viewModel = viewModel
        vc.voiceController = voiceController
        vc.previewPresenter = previewPresenter
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


#endif
