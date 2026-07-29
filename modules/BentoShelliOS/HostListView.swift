#if canImport(UIKit)
import SwiftUI
import BentoFoundation
import BentoUI
import BentoWorkbench
import BentoVoiceKit
import BentoFilePreviewKit
import BentoLink

public struct HostListView: View {
    public init() {}
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var relayStore: RelayDaemonStore
    @State private var showRelayPair = false
    @State private var relayPairPrefill: PendingRelayPair?
    @State private var showOnboarding = false
    @State private var showSettings = false

    private var isCompletelyEmpty: Bool {
        relayStore.daemons.isEmpty
    }

    public var body: some View {
        Group {
            if isCompletelyEmpty {
                WelcomeFlowView(
                    onScanPair: { showRelayPair = true }
                )
            } else {
                populatedForm
            }
        }
        .background(Color.bentoShell.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .overlay(alignment: .bottom) {
            if let notice = sessionManager.evictionNotice {
                BentoToast(text: notice)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        sessionManager.evictionNotice = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sessionManager.evictionNotice)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BentoWordmark()
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showOnboarding = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(Color.bentoInkDim)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color.bentoInkDim)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Pairing a Mac via relay is the way to add a computer.
                Button {
                    showRelayPair = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.bentoEmerald)
                }
                .accessibilityIdentifier("plus")
            }
        }
        .sheet(isPresented: $showRelayPair) {
            RelayPairView(prefill: relayPairPrefill)
        }
        .onChange(of: relayStore.pendingPair) { _, new in
            guard let new else { return }
            relayPairPrefill = new
            showRelayPair = true
            relayStore.pendingPair = nil
        }
        .onAppear {
            if let pending = relayStore.pendingPair {
                relayPairPrefill = pending
                showRelayPair = true
                relayStore.pendingPair = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showOnboarding) {
            HowBentoWorksView()
        }
    }

    @ViewBuilder
    private var populatedForm: some View {
        Form {
            if !sessionManager.activeSessions.isEmpty {
                Section {
                    ForEach(sessionManager.activeSessions) { entry in
                        ActiveSessionRow(entry: entry)
                            .environmentObject(sessionManager)
                    }
                } header: {
                    BentoFormHeader("Active")
                }
                .bentoSectionStyle()
            }

            if !relayStore.daemons.isEmpty {
                Section {
                    ForEach(relayStore.daemons) { daemon in
                        NavigationLink(value: HostNavigation.sessions(Host.fromRelayDaemon(daemon))) {
                            RelayDaemonRow(daemon: daemon)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                relayStore.delete(daemon)
                            } label: {
                                Label("Unpair", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    BentoFormHeader("My Computers")
                }
                .bentoSectionStyle()
            }

        }
        .bentoForm()
    }
}

public enum HostNavigation: Hashable {
    case sessions(Host)
}

// MARK: - Wordmark

struct BentoWordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            BentoMark(size: 22)
            Text("Bento")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.bentoInk)
        }
    }
}

// MARK: - Rows

/// Relay/Mac row in the My Computers section.
struct RelayDaemonRow: View {
    let daemon: RelayDaemon

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.bentoVeg.opacity(0.16))
                Image(systemName: "macbook")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.bentoVeg)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(daemon.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                    .lineLimit(1)
                Text("Paired \(daemon.pairedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(Color.bentoInkDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
    }
}

/// Active workspace session row.
struct ActiveSessionRow: View {
    let entry: SessionManager.WorkspaceEntry
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject private var viewModel: WorkspaceViewModel
    @State private var showDisconnect = false

    init(entry: SessionManager.WorkspaceEntry) {
        self.entry = entry
        self.viewModel = entry.viewModel
    }

    private var awaitingPanes: Int {
        viewModel.paneViewModels.reduce(0) { acc, p in
            if case .awaitingInput = p.paneState { return acc + 1 }
            return acc
        }
    }

    private var paneCount: Int { viewModel.paneViewModels.count }

    private var sessionLabel: String {
        entry.key.workspaceName.isEmpty ? "Workspace" : entry.key.workspaceName
    }

    private var statusColor: Color {
        switch viewModel.phase {
        case .ready:     return .bentoEmerald
        case .starting:  return .bentoSalmon
        case .suspended: return .bentoInkDim
        case .ended:     return .bentoRed
        }
    }

    private var isLive: Bool { viewModel.phase == .ready }

    private var subtitle: String {
        if paneCount > 0 {
            return "\(sessionLabel) · \(paneCount) pane\(paneCount == 1 ? "" : "s")"
        }
        return sessionLabel
    }

    var body: some View {
        Button {
            sessionManager.navigationPath = [.sessions(entry.host)]
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.16))
                        .frame(width: 22, height: 22)
                    if isLive {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(statusColor)
                            .scaleEffect(0.8)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.host.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.bentoInk)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bentoInkDim)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if awaitingPanes > 0 {
                    StatusPill(label: "\(awaitingPanes) waiting", color: .bentoSalmon)
                }
            }
            .padding(.vertical, 4)
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
}

// MARK: - Status pill

struct StatusPill: View {
    let label: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Toast

struct BentoToast: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.bentoSalmon)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.bentoInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color.bentoSurface)
        )
        .overlay(
            Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1)
        )
    }
}

#endif
