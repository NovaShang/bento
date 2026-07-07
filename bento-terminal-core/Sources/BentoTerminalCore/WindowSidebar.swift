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

    public init(viewModel: TerminalViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(viewModel.windows) { window in
                    row(window)
                }
            }
            .listStyle(.sidebar)

            Divider()
            newWindowMenu
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

    private func row(_ window: TmuxWindow) -> some View {
        let isActive = window.id == viewModel.activeWindowID
        return Button {
            viewModel.selectWindow(window.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor(viewModel.windowState(window.id)))
                    .frame(width: 8, height: 8)
                Text(viewModel.windowDisplayName(window.id))
                    .lineLimit(1)
                    .fontWeight(isActive ? .semibold : .regular)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isActive ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)) : nil
        )
        .contextMenu {
            Button("Close Window", role: .destructive) { pendingClose = window.id }
        }
    }

    /// Shared dot semantics: awaiting input (amber) → working (green) → idle.
    private func dotColor(_ state: PaneState) -> Color {
        switch state {
        case .awaitingInput: return .yellow
        case .working: return .green
        default: return .secondary.opacity(0.5)
        }
    }

    /// The two creation seeds, same as everywhere else.
    private var newWindowMenu: some View {
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
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("New Window")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
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
