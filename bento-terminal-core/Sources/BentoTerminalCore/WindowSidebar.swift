import SwiftUI
import SwiftTmux

/// List mode's window switcher for the big screens — ONE implementation
/// shared by macOS (hosted in an `NSHostingView`) and iPad. Native sidebar
/// styling; each row is a window with its live display name and aggregate
/// state dot. The phone uses the bottom tab bar instead.
///
/// Per the two-mode design: no rename (names derive from what's running),
/// creation offers exactly the two seeds (duplicate current / specify
/// path+command), and closing confirms because processes die.
@MainActor
public struct WindowSidebar: View {
    @ObservedObject var viewModel: TerminalViewModel
    @State private var pendingClose: TmuxWindowID?
    @State private var showCustomSheet = false
    @State private var hoveredWindow: TmuxWindowID?

    public init(viewModel: TerminalViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Native selection (accent pill) owns the row background untouched.
            // State lives entirely INSIDE the row content — the window name is
            // tinted by state and a trailing semantic glyph flags working /
            // awaiting — so it can never collide with or overflow the pill.
            List(selection: selectionBinding) {
                ForEach(viewModel.windows) { window in
                    row(window)
                        .tag(window.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)   // let the vibrancy chrome show

            newWindowButton
        }
        .confirmationDialog(
            closeDialogTitle,
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close Window", role: .destructive) {
                if let id = pendingClose { viewModel.closeWindow(id) }
                pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text("The processes running in it will be terminated.")
        }
        .sheet(isPresented: $showCustomSheet) {
            NewWindowForm { path, command in
                Task { await viewModel.newListWindow(.custom(path: path, command: command)) }
            }
        }
    }

    private var closeDialogTitle: String {
        let name = pendingClose.map { viewModel.windowDisplayName($0) } ?? ""
        return "Close “\(name)”?"
    }

    /// Selection mirrors the session's current window; picking a row is
    /// select-window. (List drives the native highlight from this binding.)
    private var selectionBinding: Binding<TmuxWindowID?> {
        Binding(
            get: { viewModel.activeWindowID },
            set: { id in if let id, id != viewModel.activeWindowID { viewModel.selectWindow(id) } }
        )
    }

    private func row(_ window: TmuxWindow) -> some View {
        let isSelected = window.id == viewModel.activeWindowID
        let state = viewModel.windowState(window.id)
        return HStack(spacing: 6) {
            name(window.id, state: state, selected: isSelected)
                .lineLimit(1)
            Spacer(minLength: 6)
            // The selected row is the one you're already looking at, so the tile
            // carries its state — skip the glyph there to keep the accent pill clean.
            if !isSelected { stateIcon(state) }
            closeButton(window.id)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredWindow = window.id }
            else if hoveredWindow == window.id { hoveredWindow = nil }
        }
        .contextMenu {
            Button("Close Window", role: .destructive) { pendingClose = window.id }
        }
    }

    /// The window name, tinted by state on unselected rows; the selected row
    /// keeps the native selection label color (no explicit tint) so colored text
    /// never fights the accent pill.
    @ViewBuilder
    private func name(_ id: TmuxWindowID, state: PaneState, selected: Bool) -> some View {
        let label = Text(viewModel.windowDisplayName(id))
        if selected {
            label
        } else {
            label.foregroundStyle(nameColor(state))
        }
    }

    /// Text tint mirroring the canonical state palette (`PaneState.dotColorHex`):
    /// working green / awaiting amber / idle default. Single source of truth
    /// shared with the pane chrome.
    private func nameColor(_ state: PaneState) -> Color {
        switch state {
        case .working, .awaitingInput: return Color(rgbHex: state.dotColorHex)
        case .idle:                    return .primary
        }
    }

    /// Trailing state glyph — the second, redundant channel next to the tinted
    /// name. Working = cycling arrows, awaiting = amber warning triangle, idle =
    /// nothing (a quiet row). Not a dot; colored from the canonical palette.
    @ViewBuilder
    private func stateIcon(_ state: PaneState) -> some View {
        switch state {
        case .working:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(rgbHex: state.dotColorHex))
        case .awaitingInput:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(rgbHex: state.dotColorHex))
        case .idle:
            EmptyView()
        }
    }

    /// Trailing per-row close affordance. Faint at rest, full on hover (pointer
    /// devices); the always-visible faint state keeps it reachable on touch.
    /// Routes through the same confirm dialog as the context menu.
    private func closeButton(_ id: TmuxWindowID) -> some View {
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
        .help("Close Window")
        .opacity(hoveredWindow == id ? 1 : 0.35)
    }

    /// Bottom-edge creation affordance, styled like Mail/Notes' "New …"
    /// footer: borderless, secondary, leading-aligned. Two seeds inside.
    private var newWindowButton: some View {
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
            Label("New Window", systemImage: "plus.circle")
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

/// The "specify path + command" mini-form. Empty command = plain shell;
/// empty path = inherit the current pane's directory.
@MainActor
struct NewWindowForm: View {
    var onCreate: (String?, String?) -> Void
    @State private var path = ""
    @State private var command = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Window").font(.headline)
            TextField("Working directory (empty = current)", text: $path)
                .textFieldStyle(.roundedBorder)
            TextField("Command (empty = shell)", text: $command)
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
