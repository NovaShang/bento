import SwiftUI
import BentoCore

/// Workspace-level driver for the iOS file preview — the conduit between the
/// UIKit pane (`AgentChatVC`, which taps file paths) and the SwiftUI
/// `WorkspaceScreen` (which presents the panel). Mirrors the macOS
/// `PreviewDockModel`: a permanent Files tree tab plus an ordered set of opened
/// file tabs. One per workspace screen.
@MainActor
final class FilePreviewPresenter: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var tabs: [OpenPreview] = []
    /// nil selects the Files tree tab.
    @Published var selectedID: String?
    /// Bumped when the active pane changes so the tree re-roots.
    @Published private(set) var treeGeneration = 0

    /// Resolves the active pane's file context at load time (set by the screen).
    var treeContextProvider: () -> PathPreviewContext? = { nil }

    var selected: OpenPreview? { tabs.first { $0.id == selectedID } }

    /// Browse the active pane's working directory (the file-tree trigger).
    func browseFiles() {
        selectedID = nil
        treeGeneration &+= 1
        isPresented = true
    }

    /// Open a specific file (the tapped-path trigger). `path` is the tapped
    /// token; the loader resolves it against the context's cwd.
    func open(path: String, line: Int?, context: PathPreviewContext) {
        if let existing = tabs.first(where: { $0.id == path }) {
            existing.reload()
            selectedID = existing.id
        } else {
            let tab = OpenPreview(path: path, line: line, context: context)
            tabs.append(tab)
            selectedID = tab.id
        }
        isPresented = true
    }

    func close(_ id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if selectedID == id {
            selectedID = idx < tabs.count ? tabs[idx].id : tabs.last?.id
        }
    }

    func dismiss() { isPresented = false }
}

/// One opened file tab: loads itself through the shared `FilePreviewLoader`
/// (resolve → stat → read → classify) over the pane's transport.
@MainActor
final class OpenPreview: ObservableObject, Identifiable {
    let id: String        // the tapped path — also the dedupe key
    let path: String
    let line: Int?
    let context: PathPreviewContext
    let title: String

    enum Phase {
        case loading
        case loaded(FilePreviewData)
        case failed(String)
    }
    @Published var phase: Phase = .loading

    private var task: Task<Void, Never>?

    init(path: String, line: Int?, context: PathPreviewContext) {
        self.id = path
        self.path = path
        self.line = line
        self.context = context
        self.title = (path as NSString).lastPathComponent
        reload()
    }

    func reload() {
        task?.cancel()
        let path = path, line = line, context = context
        task = Task { @MainActor [weak self] in
            do {
                let data = try await FilePreviewLoader.load(path: path, line: line, context: context)
                guard !Task.isCancelled else { return }
                self?.phase = .loaded(data)
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Panel

/// The panel body — a tab bar (Files + opened files) over the content, reused
/// by the compact sheet and the regular-width side dock. File rendering and the
/// tree are the shared `FilePreviewContentView` / `FileTreeBrowserView`.
struct FilePreviewPanelView: View {
    @ObservedObject var presenter: FilePreviewPresenter
    /// The side dock (iPad) shows a close button; the sheet has its grabber.
    var showsClose: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .background(Color(.systemBackground))
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(title: "Files", icon: "folder", active: presenter.selectedID == nil,
                         closable: false, select: { presenter.selectedID = nil }, close: {})
                    ForEach(presenter.tabs) { tab in
                        chip(title: tab.title, icon: "doc.text", active: tab.id == presenter.selectedID,
                             closable: true, select: { presenter.selectedID = tab.id },
                             close: { presenter.close(tab.id) })
                    }
                }
                .padding(.horizontal, 10)
            }
            if showsClose {
                Button { presenter.dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 10)
            }
        }
        .padding(.vertical, 8)
    }

    private func chip(title: String, icon: String, active: Bool, closable: Bool,
                      select: @escaping () -> Void, close: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Button(action: select) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 11))
                    Text(title).font(.system(size: 13)).lineLimit(1)
                }
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if closable {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
    }

    @ViewBuilder private var content: some View {
        if let tab = presenter.selected {
            OpenPreviewContent(tab: tab)
                .id(tab.id)
        } else {
            FileTreeBrowserView(
                reloadKey: presenter.treeGeneration,
                contextProvider: presenter.treeContextProvider,
                onOpenFile: { path, ctx in presenter.open(path: path, line: nil, context: ctx) })
        }
    }
}

private struct OpenPreviewContent: View {
    @ObservedObject var tab: OpenPreview

    var body: some View {
        switch tab.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let data):
            FilePreviewContentView(data: data, showsEscHint: false)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Adaptive presentation

/// iPhone → a sheet; iPad (regular width) → a trailing side dock, matching the
/// macOS preview dock. Attach to the workspace body.
struct FilePreviewPresentation: ViewModifier {
    @ObservedObject var presenter: FilePreviewPresenter
    let isRegularWidth: Bool

    func body(content: Content) -> some View {
        if isRegularWidth {
            content
                .overlay(alignment: .trailing) {
                    if presenter.isPresented {
                        HStack(spacing: 0) {
                            Divider()
                            FilePreviewPanelView(presenter: presenter, showsClose: true)
                                .frame(width: 420)
                        }
                        .frame(maxHeight: .infinity)
                        .background(Color(.systemBackground))
                        .transition(.move(edge: .trailing))
                    }
                }
                .animation(.snappy(duration: 0.25), value: presenter.isPresented)
        } else {
            content.sheet(isPresented: $presenter.isPresented) {
                FilePreviewPanelView(presenter: presenter)
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

extension View {
    func filePreviewPanel(_ presenter: FilePreviewPresenter, isRegularWidth: Bool) -> some View {
        modifier(FilePreviewPresentation(presenter: presenter, isRegularWidth: isRegularWidth))
    }
}
