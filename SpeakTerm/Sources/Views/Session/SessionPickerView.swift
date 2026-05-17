import SwiftUI

/// Sheet shown after SSH connects, asking the user how to start their tmux
/// session — or skip tmux entirely.
struct SessionPickerView: View {
    @ObservedObject var viewModel: TerminalViewModel
    let onPick: (TmuxStartChoice) -> Void
    let onCancel: () -> Void

    @State private var newSessionName: String = "speakterm"

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.sessionsLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Looking for tmux sessions…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !viewModel.availableTmuxSessions.isEmpty {
                    Section {
                        ForEach(viewModel.availableTmuxSessions, id: \.self) { name in
                            existingSessionRow(name: name)
                        }
                    } header: {
                        Text("Existing tmux sessions")
                    } footer: {
                        Text("Tap to attach. Use the menu for \"share with desktop\" (creates a grouped <name>-mobile session).")
                    }
                }

                Section {
                    HStack {
                        TextField("Session name", text: $newSessionName)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        Button("Create") {
                            onPick(.createOrAttach(name: newSessionName))
                        }
                        .disabled(newSessionName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("New tmux session")
                } footer: {
                    Text("Creates a new session sized to your phone screen. If a session with this name already exists, attaches to it instead.")
                }

                Section {
                    Button {
                        onPick(.noTmux)
                    } label: {
                        Label("Connect without tmux", systemImage: "terminal")
                    }
                } footer: {
                    Text("Plain shell — no split panes or session persistence.")
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refreshTmuxSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.sessionsLoading)
                }
            }
        }
    }

    @ViewBuilder
    private func existingSessionRow(name: String) -> some View {
        Button {
            onPick(.createOrAttach(name: name))
        } label: {
            HStack {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .foregroundStyle(.primary)
                    Text("attach to existing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        onPick(.createOrAttach(name: name))
                    } label: {
                        Label("Attach", systemImage: "arrow.right.circle")
                    }
                    Button {
                        onPick(.shareWithDesktop(target: name))
                    } label: {
                        Label("Share with desktop", systemImage: "rectangle.connected.to.line.below")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

}
