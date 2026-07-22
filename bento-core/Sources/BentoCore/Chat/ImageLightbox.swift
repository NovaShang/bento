import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Tap any transcript image — user attachment, agent-sent block, or tool output
// — to see it big. All three funnel through `AcpMessageImages`, which calls the
// `presentImageLightbox` environment action; `AcpSessionContentView` owns the
// state and draws `AcpImageLightbox` as a full-pane overlay above the composer.

// MARK: - Environment action

/// Opens the full-pane image viewer. Injected by `AcpSessionContentView`;
/// defaults to a no-op so `AcpMessageImages` stays inert when rendered outside a
/// session surface (SwiftUI previews, tests).
struct AcpImageLightboxAction {
    let present: ([Data], Int) -> Void
    func callAsFunction(_ images: [Data], _ index: Int) { present(images, index) }
    static let noop = AcpImageLightboxAction { _, _ in }
}

private struct AcpImageLightboxKey: EnvironmentKey {
    static let defaultValue = AcpImageLightboxAction.noop
}

extension EnvironmentValues {
    var presentImageLightbox: AcpImageLightboxAction {
        get { self[AcpImageLightboxKey.self] }
        set { self[AcpImageLightboxKey.self] = newValue }
    }
}

/// What the lightbox is currently showing: the set of sibling images from one
/// message/tool run, plus which one was tapped.
struct AcpLightboxState {
    var images: [Data]
    var index: Int
}

// MARK: - The viewer

/// Full-pane image viewer. Dark scrim (click to dismiss), the image fitted with
/// breathing room, and — when a message carries several images — paging
/// chevrons + a counter. Pinch or double-tap zooms in for a closer look on a
/// screenshot; drag pans while zoomed. Escape closes.
struct AcpImageLightbox: View {
    let images: [Data]
    let onClose: () -> Void
    @State private var index: Int
    /// Drives the fade-IN only. Removal is a clean structural drop (see the
    /// overlay wiring in AcpSessionContentView) — animating the exit is what
    /// stranded the click-blocking layer.
    @State private var shown = false

    init(images: [Data], index: Int, onClose: @escaping () -> Void) {
        self.images = images
        self._index = State(initialValue: index)
        self.onClose = onClose
    }

    private var hasMultiple: Bool { images.count > 1 }

    var body: some View {
        ZStack {
            // The scrim dims the whole pane; a click anywhere OFF the image
            // dismisses. (Taps that land on the fitted image are swallowed by
            // its own double-tap-to-zoom gesture, so only the margins close.)
            Rectangle()
                .fill(.black.opacity(0.82))
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            if images.indices.contains(index) {
                AcpZoomableImage(data: images[index])
                    // New identity per page → fresh zoom/pan state.
                    .id(index)
                    .padding(.horizontal, hasMultiple ? 64 : 40)
                    .padding(.vertical, 60)
            }

            if hasMultiple {
                HStack {
                    pageButton(system: "chevron.left", to: index - 1, key: .leftArrow)
                    Spacer()
                    pageButton(system: "chevron.right", to: index + 1, key: .rightArrow)
                }
                .padding(.horizontal, 10)
            }

            topBar
        }
        .ignoresSafeArea()
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.16)) { shown = true } }
        #if os(macOS)
        .onExitCommand(perform: onClose)
        #endif
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                if hasMultiple {
                    Text("\(index + 1) / \(images.count)")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.4), in: Capsule())
                }
                Spacer()
                circleButton(system: "xmark", size: 34) { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
            }
            .padding(16)
            Spacer()
        }
    }

    private func pageButton(system: String, to target: Int, key: KeyEquivalent) -> some View {
        let enabled = images.indices.contains(target)
        return circleButton(system: system, size: 44) {
            if enabled { withAnimation(.easeOut(duration: 0.12)) { index = target } }
        }
        .keyboardShortcut(key, modifiers: [])
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.25)
    }

    private func circleButton(system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.4), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Zoomable image

/// The enlarged image. Fits the available space; pinch or double-tap zooms in,
/// drag pans while zoomed. A single tap is intentionally inert — the viewer
/// dismisses from the surrounding scrim, not the image itself.
private struct AcpZoomableImage: View {
    let data: Data

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pan: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        image
            .scaleEffect(scale * pinch)
            .offset(x: offset.width + pan.width, y: offset.height + pan.height)
            .gesture(magnifyGesture)
            .simultaneousGesture(panGesture)
            .onTapGesture(count: 2) { toggleZoom() }
            .animation(.easeOut(duration: 0.18), value: scale)
            .animation(.easeOut(duration: 0.18), value: offset)
    }

    @ViewBuilder
    private var image: some View {
        #if os(macOS)
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage).resizable().scaledToFit()
        } else {
            fallback
        }
        #else
        if let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage).resizable().scaledToFit()
        } else {
            fallback
        }
        #endif
    }

    private var fallback: some View {
        Image(systemName: "photo")
            .font(.system(size: 44))
            .foregroundStyle(.white.opacity(0.5))
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                scale = min(max(scale * value.magnification, 1), maxScale)
                if scale == 1 { offset = .zero }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($pan) { value, state, _ in
                if scale > 1 { state = value.translation }
            }
            .onEnded { value in
                guard scale > 1 else { return }
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1
                offset = .zero
            } else {
                scale = 2
            }
        }
    }
}

// MARK: - Pointing-hand cursor (macOS)

#if os(macOS)
/// A pointing-hand cursor while hovered. Pops on exit AND on disappear so a row
/// recycled mid-hover (streaming, scroll reuse) doesn't leak the cursor stack.
private struct PointingHandCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    func acpPointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}
#else
extension View {
    func acpPointingHandCursor() -> some View { self }
}
#endif
