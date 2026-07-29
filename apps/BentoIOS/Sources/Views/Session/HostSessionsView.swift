import SwiftUI
import BentoCore
import BentoShelliOS

/// Second-level navigation: shows the sessions that exist on a paired Mac,
/// plus a "new session" row. Selecting any of them pushes the workspace
/// screen onto the navigation stack with the choice already applied.
struct HostSessionsView: View {
    let host: Host

    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        HostSessionsContent(host: host)
    }
}

/// Inner view: owns the transient SessionLister (workspace-store sync used purely
/// for discovery), the per-host VoiceInputController, and routes session
/// picks into the SessionManager.
private struct HostSessionsContent: View {
    let host: Host

    @EnvironmentObject private var sessionManager: SessionManager
    @StateObject private var lister: SessionLister
    @StateObject private var voiceController = VoiceInputController()

    @State private var newSessionName: String = "bento"
    @State private var pushKey: SessionKey?
    @State private var pendingChoice: SessionStartChoice?
    @State private var isStartingNew = false
    @State private var showAgentWizard = false
    @State private var showHistory = false
    /// Bumped after opens/sheet dismissal so the inline history rows refresh.
    @State private var historyTick = 0

    init(host: Host) {
        self.host = host
        _lister = StateObject(wrappedValue: SessionLister(host: host))
    }

    /// Sessions currently attached on this host, keyed by session name.
    private var activeForHost: [SessionManager.WorkspaceEntry] {
        sessionManager.sessions(forHostID: host.id)
    }

    /// Names of sessions we are already attached to (so we don't list
    /// them twice in "Other sessions").
    private var attachedNames: Set<String> {
        Set(activeForHost.map { $0.key.workspaceName })
    }

    /// Sessions on the host that we are NOT currently attached to.
    private var unattachedSessions: [String] {
        lister.sessions.filter { !attachedNames.contains($0) }
    }

    var body: some View {
        Form {
            connectionStatusSection

            if !activeForHost.isEmpty {
                activeSection
            }

            otherSessionsSection
            historySection
            newSessionSection
        }
        .bentoForm()
        .disabled(isStartingNew)
        .overlay {
            if isStartingNew {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(Color.bentoEmerald)
                        Text("Starting workspace…")
                            .font(.callout)
                            .foregroundStyle(Color.bentoInkDim)
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.bentoSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.bentoBorder, lineWidth: 1)
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isStartingNew)
        .navigationTitle(host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await lister.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(lister.isLoading)
            }
        }
        .navigationDestination(item: $pushKey) { key in
            if let entry = sessionManager.activeSessions.first(where: { $0.key == key }) {
                WorkspaceScreen(
                    viewModel: entry.viewModel,
                    voiceController: voiceController
                )
                // The workspace screen supplies its own back item, so only
                // the default back button is hidden.
                .navigationBarBackButtonHidden()
            }
        }
        .task {
            voiceController.onResult = { result in
                handleVoiceResultForActivePane(result)
            }
            await lister.refresh()
        }
        .alert("Error", isPresented: Binding(
            get: { lister.error != nil },
            set: { if !$0 { lister.clearError() } }
        )) {
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(lister.error ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var connectionStatusSection: some View {
        Section {
            HStack(spacing: 10) {
                if lister.isLoading {
                    ProgressView().controlSize(.small)
                } else if lister.error != nil {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.bentoRed)
                } else {
                    Image(systemName: "server.rack").foregroundStyle(Color.bentoEmerald)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(lister.isLoading ? "Listing workspaces…" : host.displayName)
                        .font(.body)
                        .foregroundStyle(Color.bentoInk)
                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.bentoInkDim)
                }
            }
        }
        .bentoSectionStyle()
    }

    /// Sessions on this host that already have a live VM in SessionManager.
    @ViewBuilder
    private var activeSection: some View {
        Section {
            ForEach(activeForHost) { entry in
                Button {
                    pushKey = entry.key
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Color.bentoEmerald).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayLabel(for: entry.key))
                                .foregroundStyle(Color.bentoInk)
                            Text(statusText(for: entry.viewModel))
                                .font(.caption2)
                                .foregroundStyle(Color.bentoInkDim)
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill").foregroundStyle(Color.bentoEmerald)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        sessionManager.disconnect(key: entry.key)
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            }
        } header: {
            BentoFormHeader("Active")
        } footer: {
            BentoFormFooter("Already connected. Tap to resume.")
        }
        .bentoSectionStyle()
    }

    /// Sessions on the host that are not yet attached.
    @ViewBuilder
    private var otherSessionsSection: some View {
        Section {
            if lister.isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Listing workspaces…").foregroundStyle(Color.bentoInkDim)
                }
            } else if unattachedSessions.isEmpty {
                Text("No other workspaces on this host.")
                    .font(.callout)
                    .foregroundStyle(Color.bentoInkDim)
            } else {
                ForEach(unattachedSessions, id: \.self) { name in
                    Button {
                        startNewSession(.createOrAttach(name: name))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(Color.bentoEmerald)
                            Text(name)
                                .foregroundStyle(Color.bentoInk)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.bentoInkMute)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            BentoFormHeader(activeForHost.isEmpty ? "Workspaces" : "Other workspaces")
        } footer: {
            BentoFormFooter("Tap to open a new connection and attach.")
        }
        .bentoSectionStyle()
    }

    @ViewBuilder
    private var newSessionSection: some View {
        Section {
            HStack {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .foregroundStyle(Color.bentoEmerald)
                TextField("Workspace name", text: $newSessionName)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                Button("Create") {
                    let name = newSessionName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    startNewSession(.createOrAttach(name: name))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.bentoEmerald)
                .disabled(newSessionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button {
                showAgentWizard = true
            } label: {
                Label("New agent workspace…", systemImage: "wand.and.stars")
            }
        } header: {
            BentoFormHeader("New workspace")
        } footer: {
            BentoFormFooter("Quick workspace is an empty single-pane shell. Agent workspace lets you pick an agent (Claude / Codex / …), working directory, and pane layout.")
        }
        .bentoSectionStyle()
        .sheet(isPresented: $showAgentWizard) {
            AgentSessionWizardView { spec in
                startNewSession(.createAgent(spec: spec))
            }
        }
    }

    /// Past conversations on this host (the metadata catalog): the three most
    /// recent inline, plus the full filterable panel. Tapping one reopens it
    /// (respawn + session/load) and enters the session it lands in.
    @ViewBuilder
    private var historySection: some View {
        if let store = SessionManager.acpStore(for: host) {
            let recent = store.catalogEntries().prefix(3)
            let liveIDs = store.liveSessionIDs
            if !recent.isEmpty {
                Section {
                    ForEach(Array(recent)) { entry in
                        Button {
                            openHistoryEntry(entry)
                        } label: {
                            historyRow(entry, live: liveIDs.contains(entry.acpSessionID))
                        }
                        .buttonStyle(.plain)
                        .disabled(entry.expired)
                    }
                    Button {
                        showHistory = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Color.bentoEmerald)
                            Text("All History…")
                                .foregroundStyle(Color.bentoInk)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.bentoInkMute)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    BentoFormHeader("History")
                } footer: {
                    BentoFormFooter("Past conversations — tap to continue where you left off.")
                }
                .bentoSectionStyle()
                .id(historyTick)
                .sheet(isPresented: $showHistory, onDismiss: { historyTick += 1 }) {
                    SessionHistorySheet(store: store) { entry in
                        openHistoryEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: CatalogEntry, live: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.expired
                ? "clock.badge.xmark" : "bubble.left.and.bubble.right")
                .foregroundStyle(entry.expired ? Color.bentoInkMute : Color.bentoEmerald)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .foregroundStyle(entry.expired ? Color.bentoInkMute : Color.bentoInk)
                    .lineLimit(1)
                Text(historySubtitle(entry, live: live))
                    .font(.caption2)
                    .foregroundStyle(Color.bentoInkDim)
                    .lineLimit(1)
            }
            Spacer()
            if live {
                Circle().fill(Color.bentoEmerald).frame(width: 8, height: 8)
            } else if !entry.expired {
                Image(systemName: "arrow.uturn.up.circle")
                    .font(.caption)
                    .foregroundStyle(Color.bentoInkMute)
            }
        }
        .contentShape(Rectangle())
    }

    private func historySubtitle(_ entry: CatalogEntry, live: Bool) -> String {
        var parts = [SessionHistoryModel.agentName(entry.presetID)]
        parts.append((entry.cwd as NSString).lastPathComponent)
        parts.append(SessionHistoryView.relativeTime(entry.lastActive))
        if live { parts.append("live") }
        if entry.expired { parts.append("expired") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private func displayLabel(for key: SessionKey) -> String {
        key.workspaceName.isEmpty ? "Workspace" : key.workspaceName
    }

    private func statusText(for vm: WorkspaceViewModel) -> String {
        switch vm.phase {
        case .ready:
            let n = vm.paneViewModels.count
            return "\(n) pane\(n == 1 ? "" : "s")"
        case .starting: return "Starting…"
        case .suspended: return "Suspended"
        case .ended: return "Ended"
        }
    }

    private func handleVoiceResultForActivePane(_ result: VoiceInputController.VoiceInputResult) {
        // Voice input only makes sense once the user has pushed into a
        // specific terminal — the active VM is the one at `pushKey`.
        guard let key = pushKey,
              let entry = sessionManager.activeSessions.first(where: { $0.key == key }) else {
            return
        }
        entry.viewModel.handleVoiceResult(result)
    }

    // MARK: - History

    /// Reopen a past conversation: the store places it (live pane's session →
    /// jump; else the most recent session; else a fresh one), then we enter
    /// that session — attaching a VM if none is cached yet.
    private func openHistoryEntry(_ entry: CatalogEntry) {
        guard let store = SessionManager.acpStore(for: host),
              let landed = store.openHistorySession(entry) else { return }
        historyTick += 1
        let key = SessionKey(hostID: host.id, workspaceName: landed.session)
        if sessionManager.existingViewModel(for: key) != nil {
            pushKey = key
        } else {
            startNewSession(.createOrAttach(name: landed.session))
        }
    }

    // MARK: - Pick

    /// Open a fresh VM for the picked choice, then push the workspace screen
    /// once it's attached.
    private func startNewSession(_ choice: SessionStartChoice) {
        let name: String
        switch choice {
        case .createOrAttach(let n): name = n
        case .createAgent(let spec): name = spec.workspaceName
        }
        let key = SessionKey(hostID: host.id, workspaceName: name)

        // If somehow already cached (e.g. user double-tapped), just push.
        if sessionManager.existingViewModel(for: key) != nil {
            pushKey = key
            return
        }

        guard let vm = sessionManager.viewModel(for: host, workspaceName: name) else { return }
        isStartingNew = true

        Task {
            await vm.start(choice)
            isStartingNew = false
            pushKey = key
            // Refresh the lister so the new session appears in the picker
            // next time and keeps our attached/unattached split correct.
            await lister.refresh()
        }
    }
}

/// The full history panel as a sheet: the shared SessionHistoryView wrapped
/// in a navigation bar. Owns its model so filters survive re-renders.
private struct SessionHistorySheet: View {
    let store: AgentWorkspaceStore
    let onOpen: (CatalogEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SessionHistoryModel

    init(store: AgentWorkspaceStore, onOpen: @escaping (CatalogEntry) -> Void) {
        self.store = store
        self.onOpen = onOpen
        _model = StateObject(wrappedValue: SessionHistoryModel(store: store))
    }

    var body: some View {
        NavigationStack {
            SessionHistoryView(model: model)
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onAppear {
            model.onOpen = { entry in
                dismiss()
                onOpen(entry)
            }
        }
    }
}
