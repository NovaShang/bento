import SwiftUI
import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
import PhotosUI
#endif

// Image attachment support for the ACP composer: wire-friendly re-encoding,
// staged-attachment chips, transcript thumbnails, and the platform pickers
// (NSOpenPanel / PhotosPicker). Gated by the agent's promptCapabilities.image.

/// Downscales/re-encodes composer images so base64 payloads stay reasonable
/// on a JSON-RPC line. Small images pass through untouched.
enum ImageAttachmentProcessor {
    static let maxPixelSize = 1568
    static let passthroughBytes = 1_500_000

    static func process(_ data: Data) -> (data: Data, mimeType: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        if max(width, height) <= maxPixelSize, data.count <= passthroughBytes {
            let mime = (CGImageSourceGetType(source) as String?)
                .flatMap { UTType($0)?.preferredMIMEType } ?? "image/png"
            return (data, mime)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, "image/jpeg")
    }
}

/// Images staged for the next prompt, as removable thumbnails.
struct AcpAttachmentsRow: View {
    @ObservedObject var session: AgentSessionViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.composerAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        AcpImageThumbnail(data: attachment.data, maxHeight: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(AcpPalette.panelBorder, lineWidth: 1))
                        Button {
                            session.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white, Color.black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                    }
                    .help(attachment.label)
                }
            }
        }
    }
}

/// A platform image rendered from raw data; shows a placeholder when the
/// data isn't decodable.
struct AcpImageThumbnail: View {
    let data: Data
    var maxHeight: CGFloat = 200

    var body: some View {
        #if os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: maxHeight)
        } else {
            placeholder
        }
        #else
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: maxHeight)
        } else {
            placeholder
        }
        #endif
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .background(AcpPalette.codeBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// macOS: ⌘V with an image on the pasteboard attaches it (text pastes pass
/// through untouched). iOS pastes images via the text field's own menu — a
/// no-op here.
struct AcpImagePasteModifier: ViewModifier {
    @ObservedObject var session: AgentSessionViewModel

    func body(content: Content) -> some View {
        #if os(macOS)
        if session.canAttachImages {
            content.onPasteCommand(of: [UTType.image.identifier]) { _ in
                let pasteboard = NSPasteboard.general
                for type in [NSPasteboard.PasteboardType.png, .tiff] {
                    if let data = pasteboard.data(forType: type) {
                        session.attachImage(data: data, label: "Pasted image")
                        return
                    }
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// The paperclip: file picker on macOS, photo library picker on iOS.
struct AcpAttachButton: View {
    @ObservedObject var session: AgentSessionViewModel
    #if os(iOS)
    @State private var pickerPresented = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    #endif

    var body: some View {
        #if os(macOS)
        Button(action: pickFiles) {
            Image(systemName: "paperclip")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Attach an image (or paste one)")
        #else
        Button {
            pickerPresented = true
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .photosPicker(
            isPresented: $pickerPresented, selection: $pickerSelection,
            maxSelectionCount: 4, matching: .images)
        .onChange(of: pickerSelection) { _, items in
            guard !items.isEmpty else { return }
            pickerSelection = []
            Task { @MainActor in
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        session.attachImage(data: data, label: "Photo")
                    }
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                for url in panel.urls {
                    if let data = try? Data(contentsOf: url) {
                        session.attachImage(data: data, label: url.lastPathComponent)
                    }
                }
            }
        }
    }
    #endif
}
