#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import BentoAgentPane
import AppKit
import SwiftUI

// MARK: - Hover highlight

/// Overlay drawn over the terminal surface while ⌘-hovering a recognized file
/// path: a soft accent wash + underline per visual row the token crosses.
/// Hit-test transparent — all mouse events keep flowing to the surface.
final class PathHighlightView: NSView {
    var rects: [CGRect] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }          // match the surface
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor
        for r in rects {
            ctx.setFillColor(accent.withAlphaComponent(0.18).cgColor)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -1, dy: 0),
                               cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
            // Underline hugs the bottom of the row — the "this is a link" cue.
            ctx.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.maxY - 1.5, width: r.width, height: 1.5))
        }
    }
}

// MARK: - Preview panel

/// One floating preview panel for the whole app (a new preview replaces the
/// current one, like Quick Look). Esc or the close button dismisses.
@MainActor
public final class FilePreviewPanelController {
    public static let shared = FilePreviewPanelController()
    private init() {}

    private var panel: NSPanel?
    private var model = FilePreviewPanelModel()

    /// The optional detached "Open in Window" surface — a floating panel a dock
    /// tab pops out into. (Previews open in the side dock by default now.)
    public func present(path: String, line: Int?, context: PathPreviewContext,
                        nearScreenPoint point: NSPoint) {
        let panel = ensurePanel(near: point)
        model.load(path: path, line: line, context: context)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Last user-chosen panel size, persisted across launches ("820x620").
    static let sizeKey = "path_preview_panel_size"

    private func preferredSize(near point: NSPoint) -> NSSize {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? NSScreen.main
        // Default: comfortable code width, near-full height — files are tall.
        var size = NSSize(width: 820, height: (screen?.visibleFrame.height ?? 900) - 24)
        if let parts = UserDefaults.standard.string(forKey: Self.sizeKey)?.split(separator: "x"),
           parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
           w >= 420, h >= 280 {
            size = NSSize(width: w, height: h)
        }
        // Never larger than the screen the click happened on.
        if let vis = screen?.visibleFrame {
            size.width = min(size.width, vis.width - 32)
            size.height = min(size.height, vis.height - 16)
        }
        return size
    }

    private func ensurePanel(near point: NSPoint) -> NSPanel {
        if let panel { position(panel, near: point); return panel }
        let p = EscClosablePanel(
            contentRect: NSRect(origin: .zero, size: preferredSize(near: point)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 420, height: 280)
        p.delegate = p          // saves the size the user resizes to
        p.contentView = NSHostingView(rootView: FilePreviewPanelRoot(model: model))
        position(p, near: point)
        panel = p
        return p
    }

    /// Place the panel near the click, clamped inside the screen.
    private func position(_ panel: NSPanel, near point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? NSScreen.main else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 12)
        let vis = screen.visibleFrame
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
        origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

/// NSPanel that closes on Esc (cancelOperation) — Quick Look muscle memory —
/// and remembers the size the user drags it to.
private final class EscClosablePanel: NSPanel, NSWindowDelegate {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    func windowDidEndLiveResize(_ notification: Notification) {
        UserDefaults.standard.set("\(Int(frame.width))x\(Int(frame.height))",
                                  forKey: FilePreviewPanelController.sizeKey)
    }
}

// MARK: - Model

@MainActor
final class FilePreviewPanelModel: ObservableObject {
    enum Phase {
        case loading(path: String)
        case loaded(FilePreviewData)
        case failed(path: String, message: String)
    }
    @Published var phase: Phase = .loading(path: "")

    private var task: Task<Void, Never>?

    func load(path: String, line: Int?, context: PathPreviewContext) {
        task?.cancel()
        phase = .loading(path: path)
        task = Task { [weak self] in
            do {
                let data = try await FilePreviewLoader.load(path: path, line: line, context: context)
                guard !Task.isCancelled else { return }
                self?.phase = .loaded(data)
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(path: path, message: error.localizedDescription)
            }
        }
    }
}

// MARK: - SwiftUI content

struct FilePreviewPanelRoot: View {
    @ObservedObject var model: FilePreviewPanelModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading(let path):
                VStack(spacing: 12) {
                    ProgressView()
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let path, let message):
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let data):
                FilePreviewContentView(data: data)   // the detached window itself
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }
}

// `FilePreviewContentView` + its web renderer now live in the shared
// FilePreview/ layer (used by the iOS sheet too).
#endif
