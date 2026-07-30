import SwiftUI
import AppKit
import BentoCore
import BentoMenuKit

/// MenuContent is the children of a MenuBarExtra with `.menuBarExtraStyle(.menu)`.
/// In that mode SwiftUI bridges children to a real NSMenu, so we can only use
/// Button / Text / Toggle / Menu / Divider / Section — NO custom HStack or
/// VStack at the top level. Icons come from SF Symbols via `Label`.
struct MenuContent: View {
    @EnvironmentObject var bento: BentoCLI
    @ObservedObject var app: AppDelegate

    var body: some View {
        // The rows that describe or control `bento-daemon` come from
        // BentoMenuKit — one daemon, one wording, shared with Bento Term
        // (docs/menubar-unification.md §3). This view still owns the ORDER,
        // and every product-scoped row between them, so the menu reads exactly
        // as it did before the extraction.

        // The engine is a separate long-lived process, so replacing the .app
        // does not replace it. When we detect that skew this is the first
        // thing in the menu — it explains a whole class of "I updated but
        // nothing changed" confusion, and one click resolves it.
        EngineUpdateMenuItems(
            isRestarting: app.restartingDaemon,
            isUpdatePending: app.daemonUpdatePending,
            liveAgents: app.status?.liveAgents ?? 0,
            restart: { app.confirmAndRestartDaemon() }
        )

        // Status header, then — when the daemon is down — a one-click fix
        // rather than a wall of disabled items (design doc §4.2). No "Stop
        // background service": this product has never offered one.
        DaemonStatusMenuItems(status: app.status)

        DaemonServiceMenuItems(status: app.status) {
            Task {
                try? await bento.startDaemon(relay: nil)
                await app.refresh()
            }
        }

        Divider()

        PairNewDeviceMenuItem(isEnabled: app.status != nil) {
            Windows.show(.pair, env: bento)
        }

        Button(action: { Windows.show(.wizard, env: bento) }) {
            Label("New agent workspace…", systemImage: "square.grid.2x2")
        }
        .keyboardShortcut("n")

        Button(action: { WorkspaceWindow.newWindow() }) {
            Label("Open Bento…", systemImage: "macwindow")
        }
        .keyboardShortcut("t")

        PairedDevicesMenuItem(isEnabled: app.status != nil) {
            Windows.show(.devices, env: bento)
        }

        if !app.sessions.isEmpty {
            Divider()
            Section("Workspaces · click to open") {
                SessionsMenuView(app: app)
            }
        }

        Divider()

        SettingsMenuItem()

        Button(action: { Windows.show(.firstRun, env: bento) }) {
            Label("Getting started guide…", systemImage: "questionmark.circle")
        }

        Button(action: { Task { await app.refresh() } }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r")

        Divider()

        QuitMenuItem()
    }
}

/// The session list, shared by the menubar dropdown AND the terminal toolbar's
/// Sessions button (hosted there via `NSHostingMenu`) so both behave identically:
/// clicking a session's first level (its `primaryAction`) opens it,
/// while the disclosure arrow reveals its panes + Rename + Kill.
struct SessionsMenuView: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        if app.sessions.isEmpty {
            Button("No workspaces") {}.disabled(true)
        }
        ForEach(app.sessions) { s in
            Menu {
                let panes = app.sessionPanes[s.name] ?? []
                if panes.count > 1 {
                    Section("Panes") {
                        ForEach(panes) { p in
                            Button {
                                WorkspaceWindow.focusOrOpen(session: s.name)
                                AgentWorkspaceStore.shared.selectPane(session: s.name, index: p.index)
                            } label: {
                                Label(
                                    "\(p.index + 1): \(p.name)",
                                    systemImage: p.active ? "circle.fill" : "circle"
                                )
                            }
                        }
                    }
                    Divider()
                }
                Button("Rename workspace…") {
                    if let newName = promptRename(current: s.name) {
                        AgentWorkspaceStore.shared.renameSession(s.name, to: newName)
                        Task { await app.refresh() }
                    }
                }
                Divider()
                Button("Kill workspace", role: .destructive) {
                    AgentWorkspaceStore.shared.killSession(s.name)
                    Task { await app.refresh() }
                }
            } label: {
                let isOpen = WorkspaceWindow.openSessionKeys.contains(s.name)
                Label(
                    "\(s.name)  ·  \(relativeActivity(s.lastActivity))",
                    // ✓ = already open as a Bento tab (clicking focuses it, not a
                    // duplicate); otherwise the not-loaded eye.
                    systemImage: isOpen ? "checkmark.circle.fill" : "eye.slash"
                )
            } primaryAction: {
                // Open the session (or just bring its tab forward if loaded).
                WorkspaceWindow.focusOrOpen(session: s.name)
            }
        }
    }
}

// `relativeActivity` (the "5m ago" / "just now" label both products' session
// lists use) now comes from BentoMenuKit — the lists themselves stay here,
// since they list different things.

/// promptRename pops a small modal NSAlert with just a text field. We
/// suppress the default app-icon badge so the dialog stays compact.
/// Internal so the terminal toolbar's Sessions menu can reuse the same prompt.
@MainActor
func promptRename(current: String) -> String? {
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
