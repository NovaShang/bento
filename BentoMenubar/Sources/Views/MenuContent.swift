import SwiftUI
import AppKit

/// MenuContent is the children of a MenuBarExtra with `.menuBarExtraStyle(.menu)`.
/// In that mode SwiftUI bridges children to a real NSMenu, so we can only use
/// Button / Text / Toggle / Menu / Divider / Section — NO custom HStack or
/// VStack at the top level. Icons come from SF Symbols via `Label`.
struct MenuContent: View {
    @EnvironmentObject var bento: BentoCLI
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var app: AppDelegate

    var body: some View {
        // Status header. Disabled buttons let us attach an SF Symbol via
        // Label; Text alone would render without an icon.
        Button(action: {}) {
            Label(statusLine, systemImage: statusSymbol)
        }
        .disabled(true)

        if let id = app.status?.daemonID {
            Button(action: {}) {
                Label("daemon \(id.prefix(8))…", systemImage: "terminal")
            }
            .disabled(true)
        }

        Divider()

        Button(action: { Windows.show(.pair, env: bento) }) {
            Label("Pair new iPhone…", systemImage: "iphone.and.arrow.right.outward")
        }
        .keyboardShortcut("p")
        .disabled(app.status == nil)

        Button(action: { Windows.show(.wizard, env: bento) }) {
            Label("New agent session…", systemImage: "square.grid.2x2")
        }
        .keyboardShortcut("n")

        Button(action: { Windows.show(.devices, env: bento) }) {
            Label("Paired devices…", systemImage: "lock.iphone")
        }
        .disabled(app.status == nil)

        if !app.tmuxSessions.isEmpty {
            Divider()
            Section("Sessions · click to open in Terminal") {
                ForEach(app.tmuxSessions) { s in
                    // primaryAction fires when the user clicks the label area
                    // (one-click attach). The disclosure arrow on the right
                    // opens the submenu containing rename + destructive kill.
                    Menu {
                        let windows = app.tmuxWindows[s.name] ?? []
                        if !windows.isEmpty {
                            Section("Windows") {
                                ForEach(windows) { w in
                                    Button(action: {
                                        Task { try? await TmuxCLI.attach(session: s.name, window: w.index) }
                                    }) {
                                        // Active window gets a filled dot so
                                        // the user can see what they're
                                        // already focused on.
                                        Label(
                                            "\(w.index): \(w.name)\(w.paneCount > 1 ? "  ·  \(w.paneCount) panes" : "")",
                                            systemImage: w.active ? "circle.fill" : "circle"
                                        )
                                    }
                                }
                            }
                            Divider()
                        }
                        Button("Rename session…") {
                            if let newName = promptRename(current: s.name) {
                                Task {
                                    try? await TmuxCLI.rename(session: s.name, to: newName)
                                    await app.refresh()
                                }
                            }
                        }
                        Divider()
                        Button("Kill session", role: .destructive) {
                            Task {
                                try? await TmuxCLI.kill(session: s.name)
                                await app.refresh()
                            }
                        }
                    } label: {
                        Label(
                            "\(s.name)  ·  \(relativeActivity(s.lastActivity))",
                            systemImage: s.attached ? "eye.fill" : "eye.slash"
                        )
                    } primaryAction: {
                        Task { try? await TmuxCLI.attach(session: s.name) }
                    }
                }
            }
        }

        Divider()

        Button(action: {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }) {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Button(action: { Task { await app.refresh() } }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r")

        Divider()

        Button(action: { NSApp.terminate(nil) }) {
            Label("Quit Bento", systemImage: "power")
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard let s = app.status else { return "Daemon not running" }
        if s.relayConnected {
            return "Connected · \(s.pairedDevices) device\(s.pairedDevices == 1 ? "" : "s")"
        }
        return "Daemon up · relay offline"
    }

    private var statusSymbol: String {
        guard let s = app.status else { return "xmark.circle" }
        return s.relayConnected ? "wifi" : "wifi.exclamationmark"
    }
}

/// relativeActivity returns a macOS-conventional "5m ago" / "just now"
/// string. RelativeDateTimeFormatter isn't `Sendable` in Swift 6, so we
/// allocate one per call (cheap — under 0.1ms per call in practice).
private func relativeActivity(_ date: Date) -> String {
    if date == .distantPast { return "—" }
    let now = Date()
    if now.timeIntervalSince(date) < 60 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: now)
}

/// promptRename pops a small modal NSAlert with just a text field. We
/// suppress the default app-icon badge so the dialog stays compact.
@MainActor
private func promptRename(current: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Rename “\(current)”"
    alert.informativeText = ""
    // Suppress the default Bento icon on the left — a rename prompt doesn't
    // need a branded badge.
    alert.icon = NSImage(size: NSSize(width: 1, height: 1))
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = current
    field.selectText(nil)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != current else { return nil }
    return trimmed
}
