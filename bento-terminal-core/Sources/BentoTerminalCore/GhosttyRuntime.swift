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

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // The prebuilt GhosttyKit has no palette-setter API, so terminal colors
        // are set via a config file: point ghostty at a Bento-private XDG dir and
        // write the active theme's palette there (verified to recolor cells).
        // `load_default_files` below picks it up; theme changes rewrite + reload.
        GhosttyRuntime.writeColorConfig(theme: ThemeStore.shared.current)
        #endif

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

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // Re-apply the palette live when the user picks a different theme.
        for name in [Notification.Name.terminalThemeChanged, .terminalFontChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in GhosttyRuntime.shared.reapplyColors() }
            }
        }
        #endif
    }

    deinit {
        tickTimer?.invalidate()
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// Write the theme's palette into a private XDG ghostty config and point
    /// ghostty at it via `XDG_CONFIG_HOME`. (No palette-setter API in the
    /// prebuilt binary, so a config file is the only route to custom colors.)
    /// The "system" theme writes no colors → ghostty uses its built-in defaults.
    private static func writeColorConfig(theme: TerminalColorTheme) {
        let fm = FileManager.default
        guard let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let xdg = appSup.appendingPathComponent("Bento/xdg", isDirectory: true)
        let ghosttyDir = xdg.appendingPathComponent("ghostty", isDirectory: true)
        try? fm.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)

        var lines: [String] = []
        if theme.id != TerminalColorTheme.systemID {
            lines.append(String(format: "background = %06X", theme.bg))
            lines.append(String(format: "foreground = %06X", theme.fg))
            lines.append(String(format: "cursor-color = %06X", theme.cursor))
            for (i, c) in theme.ansi.prefix(16).enumerated() {
                lines.append(String(format: "palette = %d=#%06X", i, c))
            }
        }
        // Font family is app-wide (no per-surface family field); font SIZE stays
        // per-surface (cfg.font_size). nil token → ghostty's default font.
        if let family = ThemeStore.shared.ghosttyFontFamily {
            lines.append("font-family = \(family)")
        }
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: ghosttyDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        setenv("XDG_CONFIG_HOME", xdg.path, 1)
    }

    /// Rewrite the color config for the current theme and push it to the running
    /// app so open surfaces recolor live (no relaunch).
    private func reapplyColors() {
        guard let app else { return }
        GhosttyRuntime.writeColorConfig(theme: ThemeStore.shared.current)
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        ghostty_app_update_config(app, cfg)
    }
    #endif

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
