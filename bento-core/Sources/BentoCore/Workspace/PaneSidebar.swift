import SwiftUI

/// Focus mode's pane switcher for the big screens — ONE implementation
/// shared by macOS (hosted in an `NSHostingView`) and iPad. Native sidebar
/// styling; each row is a PANE with its live display name and state glyph.
/// (Windows are gone — every item here is a pane.)
/// The phone uses the bottom tab bar instead.
///
/// No rename (names derive from what's running), creation offers exactly the
/// two seeds (duplicate current / specify path+command), and closing
/// confirms because processes die.
@MainActor
public struct PaneSidebar: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var pendingClose: PaneID?
    @State private var showCustomSheet = false
    @State private var hoveredPane: PaneID?
    @State private var pendingMove: PaneID?
    @State private var moveSessionName = ""

    public init(viewModel: WorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // Native selection (accent pill) owns the row background untouched.
        // State lives entirely INSIDE the row content — the pane name is
        // tinted by state and a leading semantic glyph flags working /
        // awaiting — so it can never collide with or overflow the pill.
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                ForEach(viewModel.sessionPanes, id: \.id) { pane in
                    row(pane)
                        .tag(pane.id)
                }
                .onMove { source, destination in
                    viewModel.reorderPanes(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)   // let the vibrancy chrome show

            Divider()

            // "New Pane" and "History" ride their OWN sidebar list pinned to
            // the bottom: the shared `.sidebar` style token means they keep the
            // exact row inset/height/font/hover of the pane rows above, while
            // staying bottom-aligned no matter how many panes there are.
            List {
                newPaneButton
                historyButton
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: 68)
        }
        .confirmationDialog(
            closeDialogTitle,
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close Pane", role: .destructive) {
                if let id = pendingClose { viewModel.closePane(id) }
                pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text("The agent running in it will be terminated.")
        }
        .sheet(isPresented: $showCustomSheet) {
            NewPaneForm { path, command in
                Task { await viewModel.newFocusPane(.custom(path: path, command: command)) }
            }
        }
        .alert("Move to New Workspace", isPresented: Binding(
            get: { pendingMove != nil },
            set: { if !$0 { pendingMove = nil } }
        )) {
            TextField("Workspace name", text: $moveSessionName)
            Button("Move") {
                if let id = pendingMove {
                    let name = moveSessionName
                    Task { await viewModel.movePane(id, toSession: name) }
                }
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: {
            Text("The pane keeps running — it moves to the new workspace.")
        }
    }

    private var closeDialogTitle: String {
        let name = pendingClose.map { viewModel.paneDisplayName($0) } ?? ""
        return "Close “\(name)”?"
    }

    /// Selection mirrors the session's active pane; picking a row selects it.
    /// (List drives the native highlight from this binding.)
    private var selectionBinding: Binding<PaneID?> {
        Binding(
            get: { viewModel.activePaneID },
            set: { id in if let id, id != viewModel.activePaneID { viewModel.selectPane(id) } }
        )
    }

    private func row(_ pane: Pane) -> some View {
        let status = viewModel.paneStatus(pane.id)
        return HStack(spacing: 6) {
            // Leading state glyph in a fixed-width slot so names stay aligned.
            // Shown on every row including the selected one — state reads the
            // same whether or not the row is current.
            stateIcon(status)
                .frame(width: 14)
            name(pane.id, status: status)
                .lineLimit(1)
            Spacer(minLength: 6)
            closeButton(pane.id)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredPane = pane.id }
            else if hoveredPane == pane.id { hoveredPane = nil }
        }
        .contextMenu {
            PaneMoveToSessionMenu(viewModel: viewModel) { session in
                Task { await viewModel.movePane(pane.id, toSession: session) }
            } onNewSession: {
                moveSessionName = ""
                pendingMove = pane.id
            }
            Button("Close Pane", role: .destructive) { pendingClose = pane.id }
        }
    }

    /// The pane name, tinted by status (idle = default color). Applied on every
    /// row including the selected one, so state color is consistent throughout.
    @ViewBuilder
    private func name(_ id: PaneID, status: PaneDisplayStatus) -> some View {
        let label = Text(viewModel.paneDisplayName(id))
        if let hex = statusHex(status) {
            label.foregroundStyle(Color(rgbHex: hex))
        } else {
            label
        }
    }

    /// The canonical palette hex for a status, or nil for idle (default color).
    /// Single source of truth shared with the pane chrome (`PaneState`).
    private func statusHex(_ status: PaneDisplayStatus) -> UInt32? {
        switch status {
        case .working:    return PaneState.workingHex
        case .awaiting:   return PaneState.awaitingHex
        case .doneUnseen: return PaneState.doneUnseenHex
        case .idle:       return nil
        }
    }

    /// Leading state glyph — same language as the Tiled pane title: working =
    /// blue play, awaiting = amber question, done = green check, idle = a quiet
    /// hollow gray ring (same `.circle` family, but empty = at rest). Colored
    /// from the canonical palette.
    @ViewBuilder
    private func stateIcon(_ status: PaneDisplayStatus) -> some View {
        switch status {
        case .working:    glyph("play.circle.fill", PaneState.workingHex)
        case .awaiting:   glyph("questionmark.circle.fill", PaneState.awaitingHex)
        case .doneUnseen: glyph("checkmark.circle.fill", PaneState.doneUnseenHex)
        case .idle:       glyph("circle", PaneState.idleHex)
        }
    }

    private func glyph(_ systemName: String, _ hex: UInt32) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12))
            .foregroundStyle(Color(rgbHex: hex))
    }

    /// Trailing per-row close affordance. Faint at rest, full on hover (pointer
    /// devices); the always-visible faint state keeps it reachable on touch.
    /// Routes through the same confirm dialog as the context menu.
    private func closeButton(_ id: PaneID) -> some View {
        Button {
            pendingClose = id
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close Pane")
        .opacity(hoveredPane == id ? 1 : 0.35)
    }

    /// A sidebar action row shaped exactly like `row(_:)`: leading glyph in a
    /// 14pt slot, title, trailing spacer. Reused as the label of the action
    /// menus so they mold to the pane rows above (same inset/height/hover).
    private func actionRow(_ title: String, _ systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 6)
        }
        .contentShape(Rectangle())
    }

    /// Creation affordance with the two seeds (duplicate current / path+command).
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
                Label("Path & Command…", systemImage: "terminal")
            }
        } label: {
            actionRow("New Pane", "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// History affordance: a menu of recent conversations for this session's
    /// folder (newest first). Picking one resumes it (respawn + session/load)
    /// as a pane in the active session, or jumps to the pane already running
    /// it. Content is rebuilt on open, so it reflects the latest catalog.
    private var historyButton: some View {
        Menu {
            let entries = viewModel.recentHistory()
            if entries.isEmpty {
                Text("No Conversations")
            } else {
                let liveIDs = viewModel.liveHistoryIDs
                ForEach(entries) { entry in
                    Button {
                        Task { await viewModel.openHistory(entry) }
                    } label: {
                        Label(
                            entry.title.isEmpty ? "Untitled" : entry.title,
                            systemImage: liveIDs.contains(entry.acpSessionID)
                                ? "dot.radiowaves.left.and.right"
                                : "clock.arrow.circlepath")
                    }
                }
            }
        } label: {
            actionRow("History", "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Resume a past conversation")
    }
}

/// "Move to Session" submenu for a pane row/tab context menu — ONE
/// implementation shared by the sidebar (macOS/iPad) and the phone's bottom
/// tabs. Lists the OTHER sessions from the cached list (a refresh kicks off
/// when the menu opens, warming the next open — menus don't update while
/// displayed) plus "New Session…". The CONTAINER owns the new-session name
/// prompt (an alert can't anchor inside the transient menu). Always
/// actionable: moving the session's last pane makes the client follow it.
@MainActor
public struct PaneMoveToSessionMenu: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let onPick: (String) -> Void
    let onNewSession: () -> Void

    public init(viewModel: WorkspaceViewModel,
                onPick: @escaping (String) -> Void,
                onNewSession: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onPick = onPick
        self.onNewSession = onNewSession
    }

    public var body: some View {
        Menu {
            let others = viewModel.availableSessions
                .filter { $0 != viewModel.activeSessionName }
            ForEach(others, id: \.self) { name in
                Button(name) { onPick(name) }
            }
            if !others.isEmpty { Divider() }
            Button {
                onNewSession()
            } label: {
                Label("New Workspace…", systemImage: "plus")
            }
        } label: {
            Label("Move to Workspace", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .onAppear {
            Task { await viewModel.refreshSessions() }
        }
    }
}

/// The "specify path + command" mini-form. Empty command = default agent;
/// empty path = inherit the current pane's directory.
@MainActor
struct NewPaneForm: View {
    var onCreate: (String?, String?) -> Void
    @State private var path = ""
    @State private var command = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Pane").font(.headline)
            TextField("Working directory (empty = current)", text: $path)
                .textFieldStyle(.roundedBorder)
            TextField("Command (empty = default agent)", text: $command)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(path.isEmpty ? nil : path, command.isEmpty ? nil : command)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
    }
}

private extension Color {
    /// Build a SwiftUI Color from a 0xRRGGBB literal, so the sidebar wash can
    /// reuse `PaneState.dotColorHex` — the same palette the pane chrome uses.
    init(rgbHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
