import Foundation

/// relativeActivity returns a macOS-conventional "5m ago" / "just now"
/// string. RelativeDateTimeFormatter isn't `Sendable` in Swift 6, so we
/// allocate one per call (cheap — under 0.1ms per call in practice).
///
/// Shared because both products' session lists (and the toolbar menus that
/// mirror them) label a row with the same "name · when" shape; the lists
/// themselves stay per-product, since they list different things.
public func relativeActivity(_ date: Date) -> String {
    if date == .distantPast { return "—" }
    let now = Date()
    if now.timeIntervalSince(date) < 60 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: now)
}
