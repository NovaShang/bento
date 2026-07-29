import AppKit
import BentoShellTermMac

/// Test hooks (BENTO_TEST_HOOKS=1) — the screenshot-driven-verification
/// family BENTO_OPEN_WINDOW started, extended for the ported shell's
/// self-check: `bento.test.action` distributed notifications drive UI states
/// without UI scripting (the CI shell has no accessibility/screen-recording
/// TCC), and "shot:<name>" renders every window's own view tree to
/// $BENTO_SHOT_DIR — the app photographing itself, no capture entitlement.
@MainActor
enum TestHooks {
    static func installIfRequested() {
        guard ProcessInfo.processInfo.environment["BENTO_TEST_HOOKS"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("bento.test.action"), object: nil, queue: .main
        ) { note in
            let action = note.object as? String ?? ""
            Task { @MainActor in perform(action) }
        }
    }

    static func perform(_ action: String) {
        if action.hasPrefix("shot:") {
            shoot(name: String(action.dropFirst("shot:".count)))
            return
        }
        switch action {
        case "palette":
            BentoTerminalWindow.presentCommandPalette()
        case "find":
            BentoPaneAction.dispatch(BentoPaneAction.findInPane)
        case "focusMode":
            frontVM().map { vm in Task { await vm.setMode(.list, force: true) } }
        case "parallelMode":
            frontVM().map { vm in Task { await vm.setMode(.tiled, force: true) } }
        case "split":
            BentoPaneAction.dispatch(BentoPaneAction.splitVertically)
        default:
            break
        }
    }

    private static func frontVM() -> TerminalViewModel? {
        for window in NSApp.orderedWindows {
            if let host = window.contentViewController?.view
                .firstSubview(ofType: GhosttyTiledPaneHost.self) {
                return host.viewModel
            }
        }
        return nil
    }

    private static func shoot(name: String) {
        guard let dir = ProcessInfo.processInfo.environment["BENTO_SHOT_DIR"] else { return }
        var index = 0
        for window in NSApp.orderedWindows where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let path = "\(dir)/shot-\(name)\(index == 0 ? "" : "-\(index)").png"
            try? png.write(to: URL(fileURLWithPath: path))
            index += 1
        }
    }
}

private extension NSView {
    func firstSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let hit = self as? T { return hit }
        for sub in subviews {
            if let found = sub.firstSubview(ofType: type) { return found }
        }
        return nil
    }
}
