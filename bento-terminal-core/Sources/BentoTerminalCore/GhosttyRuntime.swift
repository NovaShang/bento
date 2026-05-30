import Foundation
import GhosttyKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Process-wide libghostty runtime. `ghostty_init` and the `ghostty_app` are
/// global singletons; every surface is created against this one app. Mirrors
/// the lifecycle Ghostty's own apprt uses (init → config → app_new → tick loop).
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private let baseConfig: ghostty_config_t?
    private var tickTimer: Timer?

    private init() {
        guard ghostty_init(0, nil) == GHOSTTY_SUCCESS else {
            assertionFailure("ghostty_init failed")
            self.baseConfig = nil
            return
        }

        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self.baseConfig = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.handleWakeup() },
            action_cb: { _, _, _ in true },
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            write_to_host_cb: { userdata, bytes, count in
                GhosttyRuntime.handleWriteToHost(userdata, bytes, count)
            },
            close_surface_cb: { _, _ in }
        )

        self.app = ghostty_app_new(&runtime, config)
        // ghostty only renders/ticks surfaces of a focused app. Without this the
        // surface stays blank (notably on macOS).
        if let app { ghostty_app_set_focus(app, true) }
        startTickLoop()
    }

    deinit {
        tickTimer?.invalidate()
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Clone the base config with per-surface appearance applied.
    func makeSurfaceConfig(theme: TerminalTheme) -> ghostty_config_t? {
        guard let baseConfig, let config = ghostty_config_clone(baseConfig) else { return nil }
        if theme.fontSize > 0 {
            ghostty_config_set_font_size(config, Float(theme.fontSize))
        }
        if let family = theme.fontFamily, !family.isEmpty {
            family.withCString { ptr in
                _ = ghostty_config_set_font_family(config, ptr, UInt(family.utf8.count))
            }
        }
        ghostty_config_finalize(config)
        return config
    }

    private func startTickLoop() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in GhosttyRuntime.shared.tick() }
        }
    }

    // MARK: - C callbacks (non-capturing)

    private static func handleWakeup() {
        Task { @MainActor in GhosttyRuntime.shared.tick() }
    }

    private static func handleWriteToHost(
        _ userdata: UnsafeMutableRawPointer?,
        _ bytes: UnsafePointer<UInt8>?,
        _ count: Int
    ) {
        guard let userdata, let bytes, count > 0 else { return }
        let data = Data(bytes: bytes, count: count)
        DispatchQueue.main.async {
            let surface = Unmanaged<GhosttyTerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
            surface.handleHostWrite(data)
        }
    }
}
