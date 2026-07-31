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

    /// Deliberately EMPTY. `tmux -CC new-session -A -s <name>` attaches when the
    /// name already exists, so pre-filling this field with a plausible name —
    /// it used to say "bento" — turns "New session" into "silently join
    /// whatever is running under that name", which on the author's own machine
    /// was the live working session listed directly above.
    @State private var newSessionName = ""
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
                    // A failure and an empty host look identical from the
                    // outside — both are "no rows" — so say which it was.
                    // `error` was already being set here and simply never
                    // rendered, which made an unreachable host read as a
                    // reachable one with nothing running on it.
                    if let error = lister.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).foregroundStyle(.secondary)
                            Button("Try Again") { Task { await lister.refresh() } }
                        }
                    } else {
                        Text("No sessions yet").foregroundStyle(.secondary)
                    }
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

/// Session discovery for the picker: `list-sessions` on the host, read out of
/// the control client's own snapshot. The tmux twin of A's `SessionLister`.
@MainActor
final class TmuxSessionLister: ObservableObject {
    @Published private(set) var sessions: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let host: Host
    init(host: Host) { self.host = host }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // A host this product cannot dial is a different failure from a host
        // that would not answer, and saying "check the host, port and key"
        // about a relay-paired record sends the user to fix something that is
        // not wrong.
        guard case .directTCP = host.transport else {
            error = "\(host.displayName) is a paired Bento host, not an SSH host. "
                  + "Bento Term connects over SSH — add it again with a hostname."
            sessions = []
            return
        }
        switch await TmuxShell.listSessions(on: host) {
        case .success(let names):
            error = nil
            sessions = names
            TmuxShell.existingSessions = Set(names)
        case .failure(let message):
            error = message
            sessions = []
        }
    }
}
