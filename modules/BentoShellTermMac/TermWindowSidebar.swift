#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoWorkbench
import SwiftUI

/// Focus-mode's window switcher: rows are the session's tmux WINDOWS (live
/// name, state glyph, close), a "New Window" footer, and a context menu for
/// rename / move-to-session. Ported from the frozen `WindowSidebar`, re-sourced
/// off `TermWorkspaceModel.windows`.
///
/// Flagged (daemon-seam gaps): the mirror carries no window-active flag, so the
/// active row is the lowest-indexed (Parallel) window; rename/move-window are
/// wired to the model but the verbs are daemon extensions (no-op-safe today).
@MainActor
public struct TermWindowSidebar: View {
    @ObservedObject var model: TermWorkspaceModel
    @State private var pendingRename: Int?
    @State private var renameText = ""
    @State private var hovered: Int?

    public init(model: TermWorkspaceModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                ForEach(model.windows) { row in
                    windowRow(row).tag(row.index)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            Button {
                model.newWindow()
            } label: {
                Label("New Window", systemImage: "plus.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .alert("Rename Window", isPresented: renamePresented) {
            TextField("Window name", text: $renameText)
            Button("Rename") {
                if let idx = pendingRename { model.renameWindow(idx, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("tmux stops auto-naming this window from what's running in it.")
        }
    }

    private var selection: Binding<Int?> {
        Binding(
            get: { model.windows.first(where: \.active)?.index },
            set: { if let idx = $0 { model.selectWindowIndex(idx) } })
    }

    @ViewBuilder
    private func windowRow(_ row: TermWindowRow) -> some View {
        HStack(spacing: 6) {
            stateGlyph(model.aggregateStatus, active: row.active)
                .frame(width: 14)
            Text(row.displayName)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                model.moveWindow(row.index, toSession: "")   // placeholder verb (flagged)
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .opacity(hovered == row.index ? 0.7 : 0)
                .help("Close Window")
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? row.index : nil }
        .contextMenu {
            Button("Rename Window…") {
                renameText = row.name
                pendingRename = row.index
            }
        }
    }

    @ViewBuilder
    private func stateGlyph(_ status: PaneDisplayStatus, active: Bool) -> some View {
        // Only the active window aggregates live pane activity; dormant rows read idle.
        let s = active ? status : .idle
        switch s {
        case .working: Image(systemName: "play.circle.fill").foregroundStyle(color(0x0A85FF))
        case .awaiting: Image(systemName: "questionmark.circle.fill").foregroundStyle(color(0xFF9F0A))
        case .doneUnseen: Image(systemName: "checkmark.circle.fill").foregroundStyle(color(0x30D158))
        case .idle: Image(systemName: "circle").foregroundStyle(color(0x8E8E93))
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } })
    }

    private func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}
#endif
