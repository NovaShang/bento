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
    /// Workspace-level switcher for the Focus sidebar header (switch / rename /
    /// detach / kill / new). nil where there's no cross-workspace switching
    /// (iPad, or when the host doesn't provide it) → no header.
    private let switcher: WorkspaceSwitcherModel?
    @State private var pendingClose: PaneID?
    #if !canImport(AppKit) || targetEnvironment(macCatalyst)
    // iPad/phone only — macOS uses the native directory panel instead.
    @State private var showCustomSheet = false
    #endif
    @State private var hoveredPane: PaneID?
    @State private var pendingMove: PaneID?
    @State private var moveSessionName = ""

    public init(viewModel: WorkspaceViewModel, switcher: WorkspaceSwitcherModel? = nil) {
        self.viewModel = viewModel
        self.switcher = switcher
    }

    public var body: some View {
        // Native selection (accent pill) owns the row background untouched.
        // State lives entirely INSIDE the row content — the pane name is
        // tinted by state and a leading semantic glyph flags working /
        // awaiting — so it can never collide with or overflow the pill.
        VStack(spacing: 0) {
            // Workspace-level header: this window's context surface in Focus
            // (the toolbar there is agent-level). Absent on iPad / when unset.
            if let switcher {
                WorkspaceSwitcherHeader(model: switcher)
                Divider()
            }
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
        #if !canImport(AppKit) || targetEnvironment(macCatalyst)
        // iPad/phone have no native directory panel — keep the SwiftUI form
        // here. macOS routes "Path & Command…" to the same NSOpenPanel that
        // Parallel mode uses (see presentPathCommandPanel).
        .sheet(isPresented: $showCustomSheet) {
            NewPaneForm { path, command in
                Task { await viewModel.newFocusPane(.custom(path: path, command: command)) }
            }
        }
        #endif
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
                #if canImport(AppKit) && !targetEnvironment(macCatalyst)
                presentPathCommandPanel()
                #else
                showCustomSheet = true
                #endif
            } label: {
                Label("Path & Command…", systemImage: "terminal")
            }
        } label: {
            actionRow("New Agent", "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// macOS: the SAME native directory-chooser panel Parallel (Tiled) mode
    /// uses for "Split — Path & Command", routed to open a Focus-mode pane (or
    /// resume a past conversation in the chosen folder) instead of splitting —
    /// so both modes share one dialog and there's no bespoke SwiftUI form.
    private func presentPathCommandPanel() {
        let viewModel = self.viewModel
        Task { @MainActor in
            let cwd = await viewModel.activePaneWorkingDirectory()
            presentNewPaneDirectoryPanel(
                title: "New Agent", prompt: "Create", initialDirectory: cwd,
                onCreate: { path, command in
                    Task { await viewModel.newFocusPane(.custom(path: path, command: command)) }
                },
                onResume: { entry in
                    Task { await viewModel.openHistory(entry) }
                })
        }
    }
    #endif

    /// History affordance: a menu of recent conversations across ALL folders
    /// (newest first), not just this pane's directory. Picking one resumes it
    /// (respawn + session/load) as a pane in the active session, or jumps to
    /// the pane already running it. Content is rebuilt on open, so it reflects
    /// the latest catalog.
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

/// Live workspace-switcher state for the Focus sidebar header. The macOS window
/// owns one instance and refreshes it as tabs / poll ticks change; the sidebar
/// observes it. Workspace switching is a window/manager concern (each workspace
/// is a separate tab + view-model), so the actions arrive as closures the host
/// wires — the sidebar itself stays view-model-scoped.
@MainActor
public final class WorkspaceSwitcherModel: ObservableObject {
    /// One switchable workspace: its name, whether it's the current one, and its
    /// activity glyph (open + colored, or a dormant ring).
    public struct Entry: Identifiable, Equatable {
        public var name: String
        public var isCurrent: Bool
        /// Palette hex for the activity dot; nil = neutral (idle or dormant).
        public var statusHex: UInt32?
        /// Exists on the machine but not open here → hollow ring vs. filled disc.
        public var isDormant: Bool
        public var id: String { name }
        public init(name: String, isCurrent: Bool, statusHex: UInt32?, isDormant: Bool) {
            self.name = name
            self.isCurrent = isCurrent
            self.statusHex = statusHex
            self.isDormant = isDormant
        }
    }

    @Published public var currentName: String = ""
    @Published public var workspaces: [Entry] = []
    public var onSwitch: ((String) -> Void)?
    public var onNewWorkspace: (() -> Void)?
    public var onRename: (() -> Void)?
    public var onDetach: (() -> Void)?
    public var onKill: (() -> Void)?

    public init() {}
}

/// The Focus sidebar's top header: the current workspace name as a menu button
/// that switches to another open/dormant workspace or runs a workspace action
/// (new / rename / detach / kill). Shaped like a source-list account switcher.
@MainActor
struct WorkspaceSwitcherHeader: View {
    @ObservedObject var model: WorkspaceSwitcherModel

    var body: some View {
        Menu {
            let others = model.workspaces.filter { !$0.isCurrent }
            if !others.isEmpty {
                Section("Switch Workspace") {
                    ForEach(others) { ws in
                        Button {
                            model.onSwitch?(ws.name)
                        } label: {
                            Label(ws.name, systemImage: ws.isDormant ? "circle" : "circle.fill")
                        }
                    }
                }
                Divider()
            }
            Button { model.onNewWorkspace?() } label: {
                Label("New Workspace…", systemImage: "plus")
            }
            Divider()
            Button { model.onRename?() } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button { model.onDetach?() } label: {
                Label("Detach (keep running)", systemImage: "eject")
            }
            Button(role: .destructive) { model.onKill?() } label: {
                Label("Kill Workspace", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(model.currentName.isEmpty ? "Workspace" : model.currentName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Switch workspace or manage this one")
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
                .filter { $0 != viewModel.activeWorkspaceName }
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

#if !canImport(AppKit) || targetEnvironment(macCatalyst)
/// The "specify path + command" mini-form — iPad/phone only. (macOS uses the
/// native directory panel that Parallel mode shares; see presentPathCommandPanel.)
/// Empty command = default agent; empty path = inherit the current pane's directory.
@MainActor
struct NewPaneForm: View {
    var onCreate: (String?, String?) -> Void
    @State private var path = ""
    @State private var command = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Agent").font(.headline)
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
#endif

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
