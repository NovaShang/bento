#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundation
import BentoUI
import BentoVoiceKit
import BentoFilePreviewKit
import BentoWorkbench
import BentoAgentPane
import AppKit
import SwiftUI

/// The one history panel for the app (session menu "History…", the pane
/// context menu's folder-scoped variant, and the ⌘P history rows' "More").
/// A titled floating panel hosting the shared SessionHistoryView; opening
/// an entry closes the panel and hands the entry to the caller.
@MainActor
public final class SessionHistoryPanelController {
    public static let shared = SessionHistoryPanelController()
    private init() {}

    private var panel: NSPanel?
    private var model: SessionHistoryModel?

    /// Present (or re-present with a fresh filter) the history panel.
    /// `initialDirectory` pre-fills the directory filter (folder-scoped
    /// entry points); `onOpen` receives the picked entry after the panel
    /// closes.
    public func present(store: AgentWorkspaceStore,
                        initialDirectory: String? = nil,
                        onOpen: @escaping (CatalogEntry) -> Void) {
        dismiss()

        let model = SessionHistoryModel(store: store, initialDirectory: initialDirectory)
        model.onOpen = { [weak self] entry in
            self?.dismiss()
            onOpen(entry)
        }
        self.model = model

        let host = NSHostingController(rootView: SessionHistoryView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Session History"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = host
        panel.minSize = NSSize(width: 420, height: 300)
        self.panel = panel

        if let key = NSApp.keyWindow {
            let frame = key.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        model?.detach()
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
#endif
