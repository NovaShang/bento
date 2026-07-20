import SwiftUI
import SwiftTmux

/// Focus mode's pane switcher for the big screens — ONE implementation
/// shared by macOS (hosted in an `NSHostingView`) and iPad. Native sidebar
/// styling; each row is a PANE with its live display name and state glyph.
/// (Windows are gone — the file name survives until the S4 rename sweep.)
/// The phone uses the bottom tab bar instead.
///
/// No rename (names derive from what's running), creation offers exactly the
/// two seeds (duplicate current / specify path+command), and closing
/// confirms because processes die.
@MainActor
public struct WindowSidebar: View {
    @ObservedObject var viewModel: TerminalViewModel
    @State private var pendingClose: TmuxPaneID?
    @State private var showCustomSheet = false
    @State private var hoveredPane: TmuxPaneID?
    @State private var pendingMove: TmuxPaneID?
    @State private var moveSessionName = ""

    public init(viewModel: TerminalViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Native selection (accent pill) owns the row background untouched.
            // State lives entirely INSIDE the row content — the pane name is
            // tinted by state and a leading semantic glyph flags working /
            // awaiting — so it can never collide with or overflow the pill.
            List(selection: selectionBinding) {
                ForEach(viewModel.sessionPanes, id: \.id) { pane in
                    row(pane)
                        .tag(pane.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)   // let the vibrancy chrome show

            newPaneButton
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
            NewWindowForm { path, command in
                Task { await viewModel.newListWindow(.custom(path: path, command: command)) }
            }
        }
        .alert("Move to New Session", isPresented: Binding(
            get: { pendingMove != nil },
            set: { if !$0 { pendingMove = nil } }
        )) {
            TextField("Session name", text: $moveSessionName)
            Button("Move") {
                if let id = pendingMove {
                    let name = moveSessionName
                    Task { await viewModel.movePane(id, toSession: name) }
                }
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: {
            Text("The pane keeps running — it moves to the new session.")
        }
    }

    private var closeDialogTitle: String {
        let name = pendingClose.map { viewModel.paneDisplayName($0) } ?? ""
        return "Close “\(name)”?"
    }

    /// Selection mirrors the session's active pane; picking a row selects it.
    /// (List drives the native highlight from this binding.)
    private var selectionBinding: Binding<TmuxPaneID?> {
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
            WindowMoveToSessionMenu(viewModel: viewModel) { session in
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
    private func name(_ id: TmuxPaneID, status: WindowDisplayStatus) -> some View {
        let label = Text(viewModel.paneDisplayName(id))
        if let hex = statusHex(status) {
            label.foregroundStyle(Color(rgbHex: hex))
        } else {
            label
        }
    }

    /// The canonical palette hex for a status, or nil for idle (default color).
    /// Single source of truth shared with the pane chrome (`PaneState`).
    private func statusHex(_ status: WindowDisplayStatus) -> UInt32? {
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
    private func stateIcon(_ status: WindowDisplayStatus) -> some View {
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
    private func closeButton(_ id: TmuxPaneID) -> some View {
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

    /// Bottom-edge creation affordance, styled like Mail/Notes' "New …"
    /// footer: borderless, secondary, leading-aligned. Two seeds inside.
    private var newPaneButton: some View {
        Menu {
            Button {
                Task { await viewModel.newListWindow(.duplicateCurrent) }
            } label: {
                Label("Duplicate Current", systemImage: "plus.square.on.square")
            }
            Button {
                showCustomSheet = true
            } label: {
                Label("Path & Command…", systemImage: "terminal")
            }
        } label: {
            Label("New Pane", systemImage: "plus.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
public struct WindowMoveToSessionMenu: View {
    @ObservedObject var viewModel: TerminalViewModel
    let onPick: (String) -> Void
    let onNewSession: () -> Void

    public init(viewModel: TerminalViewModel,
                onPick: @escaping (String) -> Void,
                onNewSession: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onPick = onPick
        self.onNewSession = onNewSession
    }

    public var body: some View {
        Menu {
            let others = viewModel.availableTmuxSessions
                .filter { $0 != viewModel.activeTmuxSessionName }
            ForEach(others, id: \.self) { name in
                Button(name) { onPick(name) }
            }
            if !others.isEmpty { Divider() }
            Button {
                onNewSession()
            } label: {
                Label("New Session…", systemImage: "plus")
            }
        } label: {
            Label("Move to Session", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .onAppear {
            Task { await viewModel.refreshTmuxSessions() }
        }
    }
}

/// The "specify path + command" mini-form. Empty command = default agent;
/// empty path = inherit the current pane's directory.
@MainActor
struct NewWindowForm: View {
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
