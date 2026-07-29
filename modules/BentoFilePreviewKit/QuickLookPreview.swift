import Foundation
import SwiftUI
import QuickLook
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import QuickLookUI
#endif

// MARK: - The system previewer, embedded

/// Finder's preview, inside a Bento pane.
///
/// We render text/code/markdown ourselves — that's the 90% case for a coding
/// agent and Quick Look's plain-text previewer is strictly worse (no
/// highlighting, no line targeting). Everything our own renderers don't claim
/// lands here instead of a dead end: PDF, video, audio, Office/iWork, 3D,
/// fonts, RAW, and anything a vendor ships a Quick Look extension for. It is
/// the same renderer Finder's preview pane uses, installed plugins included.
///
/// Only macOS can embed a bare previewer (`QLPreviewView`). iOS has no
/// equivalent view — `QLPreviewController` brings its own chrome — so there the
/// caller presents the system sheet with `.quickLookPreview` instead of
/// inlining one.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // .compact drops Quick Look's own window chrome — the pane already
        // supplies the header (name/path/size) and footer.
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        // Tapping a filename shouldn't start playing audio at you; a video
        // preview waits for the play button, the way Finder's pane does.
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }

    /// Quick Look keeps the preview extension (and any playing media) alive
    /// until the view is told to let go.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
#endif

// MARK: - Getting the bytes onto local disk

/// Quick Look previews a *file URL*, so a pane whose files live on another
/// machine has to land them here first.
public enum QuickLookMaterializer {
    /// Where a remote fetch is written: one directory per preview, so the
    /// filename stays byte-identical (Quick Look types the file by its
    /// extension — rename it and you get the generic "no preview" card).
    private static let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("bento-quicklook", isDirectory: true)

    /// Returns the URL to hand Quick Look, plus the scratch directory to delete
    /// when the preview closes (nil when the file was already local).
    public static func materialize(fileName: String,
                                   resolvedPath: String,
                                   size: Int64,
                                   isLocal: Bool,
                                   source: FilePreviewSource?) async throws -> (url: URL, scratch: URL?) {
        // Already on this disk: preview it in place. No copy, no size limit.
        if isLocal { return (URL(fileURLWithPath: resolvedPath), nil) }

        guard let source else {
            throw FilePreviewError.unavailable("This pane can't reach the file to preview it.")
        }
        guard size <= Int64(FilePreviewLimits.quickLookRemoteBytes) else {
            throw FilePreviewError.unavailable(oversizeNote(size))
        }
        let data = try await source.read(resolvedPath: resolvedPath,
                                         maxBytes: FilePreviewLimits.quickLookRemoteBytes)
        // A short read means the transport truncated it, and half a PDF renders
        // as a corrupt PDF — refuse rather than preview a lie.
        guard Int64(data.count) >= size else {
            throw FilePreviewError.unavailable(oversizeNote(size))
        }

        let dir = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return (url, dir)
    }

    public static func discard(scratch: URL?) {
        guard let scratch else { return }
        try? FileManager.default.removeItem(at: scratch)
    }

    static func oversizeNote(_ size: Int64) -> String {
        let limit = FilePreviewLoader.sizeLabel(Int64(FilePreviewLimits.quickLookRemoteBytes))
        return "Too big to preview over the relay — \(FilePreviewLoader.sizeLabel(size)), limit \(limit)."
    }
}

// MARK: - The `.binary` bucket

/// What used to be "Binary file — no inline preview.": hand it to Quick Look.
///
/// Local panes preview immediately — the file is already on disk, so there's
/// nothing to pay. Remote panes stay on the info stub behind an explicit
/// "Preview · 43 MB" button, because the fallback means pulling the whole file
/// across the relay and `FilePreviewLimits.textBytes` exists precisely to keep
/// that from happening by surprise.
struct QuickLookFallback: View {
    let data: FilePreviewData

    @State private var url: URL?
    @State private var scratch: URL?
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        surface
            .onDisappear {
                QuickLookMaterializer.discard(scratch: scratch)
                scratch = nil
            }
    }

    @ViewBuilder private var surface: some View {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if let url {
            QuickLookPreview(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            stub
                // A local file needs no fetch — go straight in, no button.
                .task { if data.isLocal { await fetch() } }
        }
        #else
        stub
            // iOS can't inline a previewer; the system sheet owns the screen
            // and hands the binding back as nil when it's dismissed.
            .quickLookPreview($url)
            .onChange(of: url) { _, new in
                if new == nil {
                    QuickLookMaterializer.discard(scratch: scratch)
                    scratch = nil
                }
            }
        #endif
    }

    @ViewBuilder private var stub: some View {
        if loading {
            FilePreviewStub(icon: "doc", note: "Fetching \(FilePreviewLoader.sizeLabel(data.stat.size))…") {
                ProgressView().controlSize(.small)
            }
        } else if let failure {
            FilePreviewStub(icon: "doc", note: failure) { EmptyView() }
        } else if oversize {
            FilePreviewStub(icon: "doc",
                            note: QuickLookMaterializer.oversizeNote(data.stat.size)) { EmptyView() }
        } else {
            FilePreviewStub(icon: "doc", note: "No inline preview for this format.") {
                Button("Preview · \(FilePreviewLoader.sizeLabel(data.stat.size))") {
                    Task { await fetch() }
                }
                .controlSize(.small)
            }
        }
    }

    private var oversize: Bool {
        !data.isLocal && data.stat.size > Int64(FilePreviewLimits.quickLookRemoteBytes)
    }

    private func fetch() async {
        guard !loading, url == nil else { return }
        // Only a remote file needs the transport; a local one previews off the
        // disk it already sits on, context or no context.
        guard data.isLocal || data.context?.source != nil else {
            failure = "This pane can't reach the file to preview it."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let got = try await QuickLookMaterializer.materialize(
                fileName: data.fileName, resolvedPath: data.resolvedPath,
                size: data.stat.size, isLocal: data.isLocal,
                source: data.context?.source)
            #if canImport(UIKit) && !targetEnvironment(macCatalyst)
            // Don't present a sheet that can only say "No preview available" —
            // keep our own stub, which at least names the file.
            guard QLPreviewController.canPreview(got.url as NSURL) else {
                QuickLookMaterializer.discard(scratch: got.scratch)
                failure = "No preview available for this format."
                return
            }
            #endif
            scratch = got.scratch
            url = got.url
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Shared empty-state chrome

/// The centred icon + note used by every non-rendering preview state
/// (directory, undecodable image, Quick Look's gate), with room for an action.
struct FilePreviewStub<Actions: View>: View {
    let icon: String
    let note: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.quaternary)
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
