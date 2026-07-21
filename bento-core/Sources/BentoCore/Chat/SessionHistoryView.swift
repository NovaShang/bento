import SwiftUI

/// The session-history panel, shared by macOS (NSPanel) and iOS (sheet):
/// a filterable list over the metadata catalog. Rows open (= continue) the
/// conversation through the store's respawn + session/load path; live rows
/// jump to the pane already showing it; expired rows are greyed out.
@MainActor
public final class SessionHistoryModel: ObservableObject {
    @Published public var directoryFilter: String { didSet { refresh() } }
    /// nil = all agents; else a catalog presetID.
    @Published public var agentFilter: String? { didSet { refresh() } }
    @Published public var searchText: String = "" { didSet { refresh() } }
    @Published public private(set) var entries: [CatalogEntry] = []
    @Published public private(set) var liveIDs: Set<String> = []

    public let store: AgentWorkspaceStore
    /// Open (= continue) an entry. The host closes its panel/sheet first.
    public var onOpen: ((CatalogEntry) -> Void)?

    public init(store: AgentWorkspaceStore, initialDirectory: String? = nil) {
        self.store = store
        self.directoryFilter = initialDirectory ?? ""
        store.addListener(self) { [weak self] event in
            switch event {
            case .historyCatalogChanged, .structure, .workspacesChanged:
                self?.refresh()   // catalog rows; live badges follow panes
            default:
                break
            }
        }
        refresh()
    }

    /// Unhook from the store (SwiftUI has no reliable deinit-on-MainActor).
    public func detach() {
        store.removeListener(self)
    }

    public func refresh() {
        let dir = directoryFilter.trimmingCharacters(in: .whitespaces)
        // The directory box filters by prefix = the whole subtree.
        var list = store.catalogEntries(cwd: dir.isEmpty ? nil : dir, subtree: true)
        if let agentFilter {
            list = list.filter { $0.presetID == agentFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.cwd.localizedCaseInsensitiveContains(query)
            }
        }
        entries = list
        liveIDs = store.liveSessionIDs
    }

    /// Distinct agents present in the catalog (the picker's choices).
    public var agentChoices: [(id: String, name: String)] {
        var seen: Set<String> = []
        var choices: [(String, String)] = []
        for entry in store.catalogEntries() where !seen.contains(entry.presetID) {
            seen.insert(entry.presetID)
            choices.append((entry.presetID, Self.agentName(entry.presetID)))
        }
        return choices.sorted { $0.1 < $1.1 }
    }

    public static func agentName(_ presetID: String) -> String {
        AgentWorkspaceStore.presetForCatalogID(presetID).0.name
    }

    public func open(_ entry: CatalogEntry) {
        guard !entry.expired else { return }
        onOpen?(entry)
    }

    public func delete(_ entry: CatalogEntry) {
        store.removeCatalogEntry(entry.acpSessionID)
    }
}

public struct SessionHistoryView: View {
    @ObservedObject private var model: SessionHistoryModel
    @State private var pendingDelete: CatalogEntry?

    public init(model: SessionHistoryModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if model.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .onDisappear { model.detach() }
        .confirmationDialog(
            "Remove from history?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let entry = pendingDelete { model.delete(entry) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Only the history entry is removed — the agent keeps its own record of the conversation.")
        }
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search titles…", text: $model.searchText)
                    .textFieldStyle(.plain)
                agentPicker
            }
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                TextField("Filter by directory (includes subfolders)…",
                          text: $model.directoryFilter)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if !model.directoryFilter.isEmpty {
                    Button {
                        model.directoryFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .font(.system(size: 13))
    }

    private var agentPicker: some View {
        Menu {
            Button("All Agents") { model.agentFilter = nil }
            Divider()
            ForEach(model.agentChoices, id: \.id) { choice in
                Button {
                    model.agentFilter = choice.id
                } label: {
                    if model.agentFilter == choice.id {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkle")
                Text(model.agentFilter.map(SessionHistoryModel.agentName) ?? "All Agents")
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .font(.system(size: 12))
            .foregroundStyle(model.agentFilter == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No past sessions match")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Closed agent panes land here — open one to continue the conversation.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var list: some View {
        List {
            ForEach(model.entries) { entry in
                row(entry)
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(entry) }
                    .contextMenu {
                        if !entry.expired {
                            Button("Open") { model.open(entry) }
                        }
                        Button("Remove from History", role: .destructive) {
                            pendingDelete = entry
                        }
                    }
                    #if os(iOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = entry
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    #endif
            }
        }
        .listStyle(.plain)
    }

    private func row(_ entry: CatalogEntry) -> some View {
        let live = model.liveIDs.contains(entry.acpSessionID)
        return HStack(spacing: 10) {
            Image(systemName: entry.expired ? "clock.badge.xmark" : "bubble.left.and.bubble.right")
                .font(.system(size: 15))
                .foregroundStyle(entry.expired ? Color.secondary : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title.isEmpty ? "Untitled" : entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if live {
                        badge("LIVE", color: .green)
                    } else if entry.expired {
                        badge("EXPIRED", color: .secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(SessionHistoryModel.agentName(entry.presetID))
                    Text("·")
                    Text(cwdTail(entry.cwd))
                        .font(.system(size: 11, design: .monospaced))
                    Text("·")
                    Text(Self.relativeTime(entry.lastActive))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !entry.expired {
                Image(systemName: live ? "arrow.right.circle" : "arrow.uturn.up.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(entry.expired ? 0.5 : 1)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
    }

    private func cwdTail(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    public static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
