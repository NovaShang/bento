import SwiftUI
import WebKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The loaded-file preview surface — header (name / path / size·date·host),
/// the content (code/markdown via `FilePreviewWebView`, an image, or an
/// info-only stub for binary/directory), and a footer. One implementation for
/// the macOS dock + detached panel and the iOS sheet; platform differences
/// (image decode, pasteboard, Reveal/Open, the detached-window button) are the
/// only branches.
public struct FilePreviewContentView: View {
    let data: FilePreviewData
    /// Non-nil in the macOS dock → an "Open in Window" button pops the tab out
    /// into a floating window. Nil in that window (and on iOS).
    var onDetach: (() -> Void)?
    /// The macOS floating window closes on Esc; the docked view / iOS sheet
    /// don't show the hint.
    var showsEscHint: Bool

    public init(data: FilePreviewData, onDetach: (() -> Void)? = nil, showsEscHint: Bool = true) {
        self.data = data
        self.onDetach = onDetach
        self.showsEscHint = showsEscHint
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(data.fileName).font(.system(size: 13, weight: .semibold))
                    if let line = data.line {
                        Text("line \(line)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(data.resolvedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, headerTopInset)
        .padding(.bottom, 10)
    }

    /// macOS panel sits under a transparent titlebar (needs room); the iOS
    /// sheet has its own grabber.
    private var headerTopInset: CGFloat {
        #if os(macOS)
        return 26
        #else
        return 12
        #endif
    }

    private var subtitle: String {
        var parts = [FilePreviewLoader.sizeLabel(data.stat.size)]
        if let m = data.stat.modified {
            parts.append(m.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(data.hostLabel)
        return parts.joined(separator: " · ")
    }

    private var iconName: String {
        switch data.content {
        case .directory: return "folder"
        case .image: return "photo"
        case .binary: return "doc"
        case .text: return "doc.text"
        }
    }

    @ViewBuilder private var content: some View {
        switch data.content {
        case .text(let text, let truncated):
            VStack(spacing: 0) {
                if text.isEmpty {
                    Text("(empty file)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WebPreviewText(fileName: data.fileName, text: text, line: data.line,
                                   imageBase: data.context.map {
                                       .init(directory: (data.resolvedPath as NSString).deletingLastPathComponent,
                                             source: $0.source)
                                   })
                }
                if truncated {
                    Text("Showing the first \(FilePreviewLoader.sizeLabel(Int64(FilePreviewLimits.textBytes))) of \(FilePreviewLoader.sizeLabel(data.stat.size))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5))
                }
            }
        case .image(let bytes):
            if let img = Self.decodeImage(bytes) {
                ScrollView([.horizontal, .vertical]) {
                    img
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1200, maxHeight: 1200)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unsupported("Couldn't decode this image.")
            }
        case .binary:
            // Everything our own renderers don't claim goes to the system
            // previewer — the same one Finder's preview pane uses.
            // Keyed by path: the dock reuses this view across files, and a
            // fresh file must not inherit the previous one's fetched URL.
            QuickLookFallback(data: data).id(data.resolvedPath)
        case .directory:
            unsupported("This is a directory.")
        }
    }

    private static func decodeImage(_ bytes: Data) -> Image? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSImage(data: bytes).map(Image.init(nsImage:))
        #elseif canImport(UIKit)
        return UIImage(data: bytes).map(Image.init(uiImage:))
        #else
        return nil
        #endif
    }

    private func unsupported(_ note: String) -> some View {
        FilePreviewStub(icon: iconName, note: note) { EmptyView() }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Copy Path") { Self.copyToPasteboard(data.resolvedPath) }
            #if os(macOS)
            if data.isLocal {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: data.resolvedPath)])
                }
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: data.resolvedPath))
                }
            }
            if let onDetach {
                Button(action: onDetach) { Label("Open in Window", systemImage: "macwindow") }
            }
            #endif
            Spacer()
            #if os(macOS)
            if showsEscHint {
                Text("esc to close")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            #endif
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private static func copyToPasteboard(_ string: String) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }
}

// MARK: - Web text/code/markdown renderer

/// highlight.js + markdown-it inside `FilePreviewWebView` — the render logic is
/// shared; only the (NS/UI)ViewRepresentable conformance splits by platform.
private struct WebPreviewText {
    let fileName: String
    let text: String
    let line: Int?
    var imageBase: FilePreviewWebView.ImageBase?

    @Environment(\.colorScheme) private var colorScheme

    struct RenderKey: Equatable {
        let fileName: String
        /// Content hash, not length — a watched file can change without
        /// changing size (an agent replacing characters in place).
        let textHash: Int
        let line: Int?
    }

    final class Coordinator {
        var rendered: RenderKey?
    }

    @MainActor func makeView() -> FilePreviewWebView { FilePreviewWebView.makePreview() }

    @MainActor func updateView(_ view: FilePreviewWebView, coordinator: Coordinator) {
        let dark = colorScheme == .dark
        let key = RenderKey(fileName: fileName, textHash: text.hashValue, line: line)
        if coordinator.rendered != key {
            coordinator.rendered = key
            view.render(fileName: fileName, text: text, line: line, dark: dark, imageBase: imageBase)
        } else {
            view.setDark(dark)
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension WebPreviewText: NSViewRepresentable {
    func makeNSView(context: Context) -> FilePreviewWebView { makeView() }
    func updateNSView(_ nsView: FilePreviewWebView, context: Context) {
        updateView(nsView, coordinator: context.coordinator)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
}
#elseif canImport(UIKit)
extension WebPreviewText: UIViewRepresentable {
    func makeUIView(context: Context) -> FilePreviewWebView { makeView() }
    func updateUIView(_ uiView: FilePreviewWebView, context: Context) {
        updateView(uiView, coordinator: context.coordinator)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
}
#endif
