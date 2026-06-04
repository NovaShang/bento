#if canImport(AppKit) || canImport(UIKit)
import CoreGraphics
import GhosttyKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Engine-level text-selection helpers shared by the iOS and macOS ghostty
/// surfaces. These are pure libghostty calls operating on a `ghostty_surface_t`
/// plus a point already converted to surface pixels — the platform views own
/// the view-point→pixel conversion (scale / orientation) and forward here, so
/// the selection logic lives in exactly one place.
@MainActor
enum GhosttySel {
    /// Select the word under `px` (emulates a double-click). Returns whether a
    /// selection now exists.
    @discardableResult
    static func selectWord(_ surface: ghostty_surface_t, px: (x: Double, y: Double)) -> Bool {
        ghostty_surface_mouse_pos(surface, px.x, px.y, GHOSTTY_MODS_NONE)
        for _ in 0..<2 {
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        }
        ghostty_surface_refresh(surface)
        return ghostty_surface_has_selection(surface)
    }

    /// Begin a left-button press at `px`. ghostty either starts a selection or
    /// forwards it to the app (when the TUI enabled mouse reporting); `mods`
    /// carries the held keyboard modifiers so modified / shift-to-select clicks
    /// work. Returns whether ghostty consumed it for the app's mouse reporting.
    @discardableResult
    static func begin(_ surface: ghostty_surface_t, px: (x: Double, y: Double),
                      mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) -> Bool {
        ghostty_surface_mouse_pos(surface, px.x, px.y, mods)
        return ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    /// Extend the in-progress drag (selection, or motion reported to the app).
    static func extend(_ surface: ghostty_surface_t, px: (x: Double, y: Double),
                       mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
        ghostty_surface_mouse_pos(surface, px.x, px.y, mods)
        ghostty_surface_refresh(surface)
    }

    /// Finish the left-button press.
    static func end(_ surface: ghostty_surface_t, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_refresh(surface)
    }

    static func hasSelection(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_has_selection(surface)
    }

    /// The currently selected text, or nil.
    static func selectedText(_ surface: ghostty_surface_t) -> String? {
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t), let ptr = t.text else { return nil }
        let s = String(bytes: UnsafeRawBufferPointer(start: ptr, count: Int(t.text_len)), encoding: .utf8)
        ghostty_surface_free_text(surface, &t)
        return s
    }

    /// Select the entire screen/scrollback via ghostty's keybind action.
    @discardableResult
    static func selectAll(_ surface: ghostty_surface_t) -> Bool {
        let action = "select_all"
        let ok = action.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
        }
        ghostty_surface_refresh(surface)
        return ok
    }

    /// Clear any selection (a plain left click collapses it).
    static func clear(_ surface: ghostty_surface_t, px: (x: Double, y: Double)?) {
        if let px { ghostty_surface_mouse_pos(surface, px.x, px.y, GHOSTTY_MODS_NONE) }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        ghostty_surface_refresh(surface)
    }

    /// Feed literal text to the surface (paste).
    static func insertText(_ surface: ghostty_surface_t, _ text: String) {
        guard !text.isEmpty else { return }
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
                ghostty_surface_text(surface, p, UInt(buf.count))
            }
        }
    }
}

/// System pasteboard bridge (one source of truth for both platforms).
@MainActor
enum TerminalClipboard {
    static func write(_ s: String) {
        guard !s.isEmpty else { return }
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = s
        #endif
    }

    static func read() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #elseif canImport(UIKit)
        return UIPasteboard.general.string
        #endif
    }
}
#endif
