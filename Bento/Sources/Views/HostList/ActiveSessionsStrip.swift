import SwiftUI

/// Horizontal strip on the host list showing all currently-attached sessions
/// (across all hosts). Tap to jump back into a session. Long-press to
/// disconnect that specific session.
struct ActiveSessionsStrip: View {
    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        if !sessionManager.activeSessions.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(sessionManager.activeSessions) { entry in
                            SessionCard(entry: entry)
                                .environmentObject(sessionManager)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } header: {
                Text("Active Sessions")
            }
        }
    }
}

/// A single card in the active sessions strip.
private struct SessionCard: View {
    let entry: SessionManager.SessionEntry
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject private var viewModel: TerminalViewModel
    @State private var showDisconnectConfirm = false

    init(entry: SessionManager.SessionEntry) {
        self.entry = entry
        self.viewModel = entry.viewModel
    }

    private var awaitingPanes: Int {
        viewModel.paneViewModels.reduce(0) { acc, p in
            if case .awaitingInput = p.paneState { return acc + 1 }
            return acc
        }
    }

    private var statusIcon: some View {
        Group {
            switch viewModel.phase {
            case .tmuxReady, .shellReady:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .sshConnecting, .choosingSession, .starting, .suspended:
                ProgressView().controlSize(.mini)
            case .ended:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private var sessionLabel: String {
        entry.key.tmuxSessionName.isEmpty ? "Shell" : entry.key.tmuxSessionName
    }

    private var detailText: String {
        if viewModel.phase == .shellReady || entry.key.tmuxSessionName.isEmpty {
            return "Shell"
        }
        let n = viewModel.paneViewModels.count
        return "\(n) pane\(n == 1 ? "" : "s")"
    }

    var body: some View {
        Button {
            // Push the picker for this host; from there user taps the matching
            // "Active" row to land in this specific session's terminal.
            sessionManager.navigationPath = [.sessions(entry.host)]
        } label: {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.host.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(sessionLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(detailText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if awaitingPanes > 0 {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text("\(awaitingPanes)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture {
            showDisconnectConfirm = true
        }
        .confirmationDialog(
            "Disconnect \(entry.host.displayName) · \(sessionLabel)?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                sessionManager.disconnect(key: entry.key)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
