#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import ACPKit
import AppKit
import SwiftUI

/// Hosts the slash-command completion panel in a borderless, non-activating
/// CHILD WINDOW anchored above the composer bar — like a menu, it can spill
/// past the pane and the app window (a SwiftUI overlay is clipped by the
/// hosting view, which crushed the panel on small panes), and it nudges
/// itself inside the screen's visible frame. The representable renders
/// nothing: it is a zero-height strip pinned to the bar's top edge whose
/// AppKit view drives the panel window.
struct AcpSlashPanelWindow: NSViewRepresentable {
    var matches: [AvailableCommand]
    var selection: Int
    var accept: (AvailableCommand) -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.update(matches: matches, selection: selection, accept: accept)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.hidePanel()
    }

    @MainActor
    final class AnchorView: NSView {
        private var panel: NSPanel?
        private var hosting: NSHostingView<AcpSlashCommandPanel>?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { hidePanel() } else { reposition() }
        }

        override func layout() {
            super.layout()
            reposition()
        }

        func update(
            matches: [AvailableCommand], selection: Int,
            accept: @escaping (AvailableCommand) -> Void
        ) {
            guard !matches.isEmpty else {
                hidePanel()
                return
            }
            let content = AcpSlashCommandPanel(
                matches: matches, selection: selection, accept: accept)
            // Window mutations are deferred out of the SwiftUI render pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor
                else { return }
                self.showPanel(content)
            }
        }

        private func showPanel(_ content: AcpSlashCommandPanel) {
            if panel == nil {
                let p = NSPanel(
                    contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: true)
                p.isOpaque = false
                p.backgroundColor = .clear
                // Menu-like window shadow; the panel view itself draws no
                // shadow on macOS (it would clip at the window edge).
                p.hasShadow = true
                p.becomesKeyOnlyIfNeeded = true
                p.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                p.contentView = host
                hosting = host
                panel = p
            }
            hosting?.rootView = content
            // Follow the pane's pinned light/dark so the panel matches the
            // canvas it floats over.
            panel?.appearance = effectiveAppearance
            reposition()
            if let panel, let window, panel.parent == nil {
                window.addChildWindow(panel, ordered: .above)
            }
            panel?.orderFront(nil)
        }

        func hidePanel() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        /// Menu-style placement: above the bar's top edge, bar-wide (with the
        /// composer's 12 pt margins), clamped into the screen's visible
        /// frame — sliding down over the bar only when the screen truly has
        /// no room above (window parked at the bottom edge).
        private func reposition() {
            guard let panel, let hosting, let window else { return }
            let rectOnScreen = window.convertToScreen(convert(bounds, to: nil))
            guard rectOnScreen.width > 0 else { return }
            let vis = (window.screen ?? NSScreen.main)?.visibleFrame ?? rectOnScreen
            let width = min(max(rectOnScreen.width - 24, 320), vis.width - 16)
            let height = hosting.fittingSize.height
            var x = rectOnScreen.minX + 12
            x = min(max(x, vis.minX + 8), vis.maxX - width - 8)
            var yBottom = rectOnScreen.maxY + 6
            if yBottom + height > vis.maxY - 8 {
                yBottom = max(vis.minY + 8, vis.maxY - 8 - height)
            }
            panel.setFrame(
                NSRect(x: x, y: yBottom, width: width, height: height), display: true)
        }
    }
}
#endif
