import SwiftUI
import BentoFoundation
import BentoWorkbench
import BentoShelliOS

/// Product B's session picker: the tmux sessions that exist on a paired Mac,
/// plus a "new session" row. The tmux twin of product A's `HostSessionsView`,
/// but leaner — no ACP history catalog (there is none for tmux panes). Picking
/// a session pushes the shared `WorkspaceScreen`, whose panes are tmux terminals.
struct HostSessionsView: View {
    let host: Host

    @EnvironmentObject private var sessionManager: SessionManager
    @StateObject private var voiceController = VoiceInputController()
    @StateObject private var lister: TmuxSessionLister

    @State private var newSessionName = "bento"
    @State private var pushKey: SessionKey?

    init(host: Host) {
        self.host = host
        _lister = StateObject(wrappedValue: TmuxSessionLister(host: host))
    }

    var body: some View {
        List {
            Section {
                ForEach(lister.sessions, id: \.self) { name in
                    Button(name) { open(sessionName: name) }
                        .font(.system(.body, design: .monospaced))
                }
                if lister.sessions.isEmpty, !lister.isLoading {
                    Text("No sessions yet").foregroundStyle(.secondary)
                }
            } header: {
                BentoFormHeader("Sessions", trailing: lister.isLoading ? "…" : nil)
            }

            Section {
                HStack {
                    TextField("name", text: $newSessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button("Open") { open(sessionName: newSessionName) }
                        .disabled(newSessionName.isEmpty)
                }
            } header: {
                BentoFormHeader("New session")
            }
        }
        .navigationTitle(host.displayName)
        .navigationDestination(item: $pushKey) { key in
            if let entry = sessionManager.activeSessions.first(where: { $0.key == key }) {
                WorkspaceScreen(viewModel: entry.viewModel, voiceController: voiceController)
                    .navigationBarBackButtonHidden()
            }
        }
        .task { await lister.refresh() }
    }

    private func open(sessionName: String) {
        guard !sessionName.isEmpty,
              sessionManager.viewModel(for: host, workspaceName: sessionName) != nil
        else { return }
        pushKey = SessionKey(hostID: host.id, workspaceName: sessionName)
    }
}

/// Session discovery for the picker: reads the tmux store's session tree,
/// synced from the paired daemon's statekv. The tmux twin of A's `SessionLister`.
@MainActor
final class TmuxSessionLister: ObservableObject {
    @Published private(set) var sessions: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let host: Host
    init(host: Host) { self.host = host }

    func refresh() async {
        guard let store = TmuxShell.store(for: host) else {
            error = "This device isn't paired with that Mac anymore. Pair again from the Mac's menu bar."
            return
        }
        isLoading = true
        _ = await store.syncWithDaemon()
        sessions = store.sessionList.map(\.name)
        isLoading = false
    }
}
