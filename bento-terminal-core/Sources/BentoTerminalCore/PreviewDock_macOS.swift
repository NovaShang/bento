#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

// MARK: - File watcher

/// Watches ONE file for content changes and calls `onChange` (debounced), so a
/// pinned preview can track the file an agent is editing. Agents/editors often
/// replace files atomically (write temp → rename), which orphans the fd — so on
/// delete/rename we re-open and re-arm. Local files only.
final class LocalFileWatcher {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.novashang.bento.filewatch")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?
    private var cancelled = false

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    private func arm() {
        guard !cancelled, fd < 0 else { return }
        let f = open(path, O_EVTONLY)
        guard f >= 0 else {
            // Mid atomic-replace (temp not yet renamed in) — retry shortly.
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.arm() }
            return
        }
        fd = f
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: f,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .link],
            queue: queue)
        src.setEventHandler { [weak self] in self?.handle(src.data) }
        src.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            close(self.fd); self.fd = -1
        }
        source = src
        src.resume()
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        let replaced = !events.isDisjoint(with: [.delete, .rename, .revoke])
        if replaced {
            source?.cancel(); source = nil   // cancel handler closes the fd
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm() }
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            self.onChange()
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func cancel() {
        cancelled = true
        queue.async { [weak self] in
            self?.debounce?.cancel()
            self?.source?.cancel(); self?.source = nil
        }
    }
}

// MARK: - Pinned preview

/// One tab in the side dock: a file, how to reload it, and its render state.
/// While pinned it watches the file (local panes) and reloads on change; the
/// WebView preserves scroll on a same-file re-render, so watching an agent edit
/// doesn't yank you to the top.
@MainActor
final class PinnedPreview: ObservableObject, Identifiable {
    let id: String            // resolvedPath — also the dedupe key
    let path: String
    let line: Int?
    let context: PathPreviewContext
    let title: String

    enum Phase {
        case loading
        case loaded(FilePreviewData)
        case failed(String)
    }
    @Published var phase: Phase

    private var watcher: LocalFileWatcher?
    private var reloadTask: Task<Void, Never>?

    /// `path` is an already-resolved absolute path. `initial` seeds the first
    /// render when the caller already has it (a detach); otherwise the tab loads
    /// itself (loading → loaded/failed).
    init(path: String, line: Int?, context: PathPreviewContext, initial: FilePreviewData?) {
        self.id = path
        self.path = path
        self.line = line
        self.context = context
        self.title = (path as NSString).lastPathComponent
        self.phase = initial.map(Phase.loaded) ?? .loading
        if context.isLocal {
            watcher = LocalFileWatcher(path: path) { [weak self] in
                Task { @MainActor in self?.reload() }
            }
        }
        if initial == nil { reload() }
    }

    func reload() {
        reloadTask?.cancel()
        let path = path, line = line, context = context
        reloadTask = Task { @MainActor [weak self] in
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

    func stop() {
        watcher?.cancel()
        watcher = nil
        reloadTask?.cancel()
    }
}

// MARK: - Dock model

/// The window's side dock: an ordered set of pinned previews + the selected one.
/// One per window (owned by `TerminalWindowManager`); persists across terminal
/// tab switches.
@MainActor
final class PreviewDockModel: ObservableObject {
    @Published private(set) var tabs: [PinnedPreview] = []
    @Published var selectedID: String?

    /// Toggle for the window to collapse/expand the split item (empty ↔ not).
    var onEmptyChanged: ((Bool) -> Void)?

    var selected: PinnedPreview? { tabs.first { $0.id == selectedID } }

    /// Open a preview as a dock tab (`path` already resolved). Re-opening a
    /// docked file just focuses + reloads its tab.
    func open(path: String, line: Int?, context: PathPreviewContext) {
        if let existing = tabs.first(where: { $0.id == path }) {
            existing.reload()
            selectedID = existing.id
            return
        }
        let wasEmpty = tabs.isEmpty
        let tab = PinnedPreview(path: path, line: line, context: context, initial: nil)
        tabs.append(tab)
        selectedID = tab.id
        if wasEmpty { onEmptyChanged?(false) }
    }

    func close(_ id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].stop()
        tabs.remove(at: idx)
        if selectedID == id {
            let fallback = idx < tabs.count ? tabs[idx].id : tabs.last?.id
            selectedID = fallback
        }
        if tabs.isEmpty { onEmptyChanged?(true) }
    }
}

// MARK: - Dock view

struct PreviewDock: View {
    @ObservedObject var model: PreviewDockModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    PreviewDockTab(
                        title: tab.title,
                        active: tab.id == model.selectedID,
                        onSelect: { model.selectedID = tab.id },
                        onClose: { model.close(tab.id) })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: 36)
    }

    /// Pop the tab out into the floating window (the optional detached surface)
    /// and drop it from the dock — "move to window".
    private func detach(_ tab: PinnedPreview) {
        let pt = NSApp.keyWindow.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) }
            ?? NSPoint(x: 400, y: 400)
        FilePreviewPanelController.shared.present(
            path: tab.path, line: tab.line, context: tab.context, nearScreenPoint: pt)
        model.close(tab.id)
    }

    @ViewBuilder private var content: some View {
        if let tab = model.selected {
            PreviewDockContent(tab: tab, onDetach: { detach(tab) })
                .id(tab.id)   // stable per tab → WebView reuse preserves scroll
        } else {
            VStack(spacing: 8) {
                Image(systemName: "pin.slash").font(.system(size: 30)).foregroundStyle(.quaternary)
                Text("Pin a preview to watch it here")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PreviewDockContent: View {
    @ObservedObject var tab: PinnedPreview
    let onDetach: () -> Void

    var body: some View {
        switch tab.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let data):
            FilePreviewContentView(data: data, onDetach: onDetach, showsEscHint: false)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PreviewDockTab: View {
    let title: String
    let active: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(active ? Color.accentColor : .secondary)
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(active ? .primary : .secondary)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering || active ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: 12, height: 12)
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: 160)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                             : (hovering ? Color.primary.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}
#endif
