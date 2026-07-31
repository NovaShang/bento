#if canImport(UIKit)
import SwiftUI
import BentoFoundation
import BentoUI
import BentoWorkbench
import BentoVoiceKit
import BentoFilePreviewKit
import BentoLink

// MARK: - Pane Tab Bar (List mode, compact width)

/// Bottom tab strip for List mode on phones: one tab per pane, browser-tab
/// style, horizontally scrollable, with a trailing "+" that offers the two
/// creation seeds. Each tab shows the pane's LIVE display name and its state
/// dot. Tapping a tab is select-pane ONLY. Long-press a tab → Move / Close
/// (confirmed: processes die).
struct PaneTabBar: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var pendingClose: PaneID?
    @State private var showCustomSheet = false
    @State private var pendingMove: PaneID?
    @State private var moveSessionName = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.sessionPanes, id: \.id) { pane in
                        PaneTab(name: viewModel.paneDisplayName(pane.id),
                                  state: viewModel.paneState(pane.id),
                                  isActive: pane.id == viewModel.activePaneID)
                            .id(pane.id)
                            .onTapGesture { viewModel.selectPane(pane.id) }
                            .contextMenu {
                                PaneMoveToSessionMenu(viewModel: viewModel) { session in
                                    movePane(pane.id, to: session)
                                } onNewSession: {
                                    moveSessionName = ""
                                    pendingMove = pane.id
                                }
                                Button(role: .destructive) {
                                    pendingClose = pane.id
                                } label: {
                                    Label("Close Pane", systemImage: "xmark")
                                }
                            }
                    }
                    newPaneButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.activePaneID) { _, newID in
                // Keep the current tab in view (a switch can come from any
                // attached device, not just a tap here).
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .background(
            // The bar owns the bottom inset: paint under the home indicator.
            Color.bentoShell.ignoresSafeArea(.container, edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Color.bentoBorder).frame(height: 1)
        }
        .alert(closeAlertTitle, isPresented: Binding(
            get: { pendingClose != nil },
            set: { if !$0 { pendingClose = nil } }
        )) {
            Button("Close Pane", role: .destructive) {
                if let id = pendingClose { viewModel.closePane(id) }
                pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text("The agent running in it will be terminated.")
        }
        .sheet(isPresented: $showCustomSheet) {
            NewPaneSheet(title: "New Pane") { path, command in
                Task { await viewModel.newFocusPane(.custom(path: path, command: command)) }
            }
        }
        .alert("Move to New Workspace", isPresented: Binding(
            get: { pendingMove != nil },
            set: { if !$0 { pendingMove = nil } }
        )) {
            TextField("Workspace name", text: $moveSessionName)
            Button("Move") {
                if let id = pendingMove { movePane(id, to: moveSessionName) }
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: {
            Text("The pane keeps running — it moves to the new workspace.")
        }
    }

    private func movePane(_ id: PaneID, to session: String) {
        Task { _ = await viewModel.movePane(id, toSession: session) }
    }

    private var closeAlertTitle: String {
        let name = pendingClose.map { viewModel.paneDisplayName($0) } ?? ""
        return "Close “\(name)”?"
    }

    /// The two creation seeds — same pair as the iPad/macOS sidebar.
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
                Label("Path & Command…", systemImage: "folder.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.bentoInkDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.bentoSurface))
                .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
    }
}

// MARK: - New pane / split "path + command" form

/// The "specify path + command" mini-sheet, shared by List's "+" menu and
/// Tiled's "Split — Path & Command…". Empty command = default agent; empty
/// path = inherit the current pane's directory.
struct NewPaneSheet: View {
    var title: String
    var onCreate: (String?, String?) -> Void

    @State private var path = ""
    @State private var command = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Working Directory") {
                    TextField("Empty = current directory", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Command") {
                    TextField("Empty = default agent", text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(path.isEmpty ? nil : path,
                                 command.isEmpty ? nil : command)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct PaneTab: View {
    var name: String
    var state: PaneState
    var isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(STTheme.dotColor(for: state)))
                .frame(width: 8, height: 8)
                .shadow(color: glowColor, radius: glowRadius)

            Text(name.isEmpty ? "pane" : name)
                .font(.footnote)
                .foregroundStyle(isActive ? Color.bentoInk : Color.bentoInkDim)
                .lineLimit(1)
                .frame(maxWidth: 140)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(isActive ? Color.bentoSurfaceHi : Color.bentoSurface))
        .overlay(
            Capsule().strokeBorder(isActive ? Color.bentoEmerald : Color.bentoBorder,
                                   lineWidth: isActive ? 1.5 : 1)
        )
        .contentShape(Capsule())
    }

    private var glowColor: Color {
        switch state {
        case .awaitingInput: return Color(STTheme.dotColor(for: state)).opacity(0.8)
        case .working: return Color(STTheme.dotColor(for: state)).opacity(0.6)
        case .idle: return .clear
        }
    }

    private var glowRadius: CGFloat {
        switch state {
        case .awaitingInput: return 3
        case .working: return 2.5
        case .idle: return 0
        }
    }
}


#endif
