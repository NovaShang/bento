#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

// The HOST-scoped rows of the menu-bar dropdown — the ones that describe or
// control `bento-daemon`, which is one process shared by both Mac products.
// Each product's MenuContent still owns the COMPOSITION (which rows, in what
// order, with which product-scoped rows between them); these types own only
// the rows' wording, symbol and shortcut, so the two menus can't drift.
//
// Where the products differ today the difference is a PARAMETER, never a
// unification: Bento Term shows "Stop background service" and Bento ACP does
// not; Bento ACP shows the engine-update prompt and Bento Term does not. Both
// render exactly what they rendered before the extraction — Bento Term's menu
// is bound by the fidelity rule in docs/term-shell-port.md.
//
// These are `MenuBarExtra` children with `.menuBarExtraStyle(.menu)`, i.e.
// SwiftUI bridges them to a real NSMenu: only Button / Text / Toggle / Menu /
// Divider / Section may appear, and icons come from SF Symbols via `Label`.

/// The status header: what the daemon is doing, and which daemon it is.
/// Disabled buttons (rather than bare `Text`) are what let us attach an SF
/// Symbol via `Label`.
public struct DaemonStatusMenuItems: View {
    private let status: DaemonStatus?

    public init(status: DaemonStatus?) {
        self.status = status
    }

    public var body: some View {
        Button(action: {}) {
            Label(
                DaemonMenuPresentation.statusLine(status),
                systemImage: DaemonMenuPresentation.statusSymbol(status)
            )
        }
        .disabled(true)

        if let id = status?.daemonID {
            Button(action: {}) {
                Label(DaemonMenuPresentation.daemonIDLine(id), systemImage: "terminal")
            }
            .disabled(true)
        }
    }
}

/// Start (and, for the products that offer it, stop) the background service.
///
/// Daemon down → a one-click fix, not a wall of disabled items (design doc
/// §4.2). Pairing and device management need it; local terminals don't.
///
/// `stop` is optional because only Bento Term surfaces the counterpart today:
/// the service outlives the GUI on purpose, so there has to be a deliberate
/// way to stop it — quitting no longer does it by accident.
public struct DaemonServiceMenuItems: View {
    private let status: DaemonStatus?
    private let start: () -> Void
    private let stop: (() -> Void)?

    public init(
        status: DaemonStatus?,
        start: @escaping () -> Void,
        stop: (() -> Void)? = nil
    ) {
        self.status = status
        self.start = start
        self.stop = stop
    }

    public var body: some View {
        if status == nil {
            Button(action: start) {
                Label("Start background service", systemImage: "play.circle")
            }
            Button(action: {}) {
                Label("Needed to pair and reach your phone", systemImage: "info.circle")
            }
            .disabled(true)
        }

        if status != nil, let stop {
            Button(action: stop) {
                Label("Stop background service", systemImage: "stop.circle")
            }
        }
    }
}

/// The engine-skew prompt. When the running daemon isn't the one this app
/// ships, this is the first thing in the menu — it explains a whole class of
/// "I updated but nothing changed" confusion, and one click resolves it.
///
/// Renders its own trailing `Divider()` so it is a single self-contained block
/// at the top of a menu, and renders nothing at all when there is no skew.
public struct EngineUpdateMenuItems: View {
    private let isRestarting: Bool
    private let isUpdatePending: Bool
    private let liveAgents: Int
    private let restart: () -> Void

    public init(
        isRestarting: Bool,
        isUpdatePending: Bool,
        liveAgents: Int,
        restart: @escaping () -> Void
    ) {
        self.isRestarting = isRestarting
        self.isUpdatePending = isUpdatePending
        self.liveAgents = liveAgents
        self.restart = restart
    }

    public var body: some View {
        if isRestarting {
            Button(action: {}) {
                Label("Restarting engine…", systemImage: "hourglass")
            }
            .disabled(true)
            Divider()
        } else if isUpdatePending {
            Button(action: restart) {
                Label("Update ready · restart engine", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(action: {}) {
                Label(EngineUpdate.hint(liveAgents: liveAgents), systemImage: "info.circle")
            }
            .disabled(true)
            Divider()
        }
    }
}

/// "Pair new iPhone…" — pairing is the identity layer and belongs to the
/// daemon, so both products offer the same row with the same shortcut.
public struct PairNewDeviceMenuItem: View {
    private let isEnabled: Bool
    private let action: () -> Void

    public init(isEnabled: Bool, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label("Pair new iPhone…", systemImage: "iphone.and.arrow.right.outward")
        }
        .keyboardShortcut("p")
        .disabled(!isEnabled)
    }
}

/// "Paired devices…" — same key store, same daemon, same row.
public struct PairedDevicesMenuItem: View {
    private let isEnabled: Bool
    private let action: () -> Void

    public init(isEnabled: Bool, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label("Paired devices…", systemImage: "lock.iphone")
        }
        .disabled(!isEnabled)
    }
}

/// "Settings…" — reads SwiftUI's `openSettings` itself, because the AppKit
/// `showSettingsWindow:` selector is a no-op in a MenuBarExtra app.
public struct SettingsMenuItem: View {
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        Button(action: {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }) {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")
    }
}

/// "Quit Bento". The title is a parameter only so the merged menu of a later
/// stage can say something else without editing every caller — both products
/// pass the same string today (docs/menubar-unification.md §7, question 2).
public struct QuitMenuItem: View {
    private let title: String

    public init(title: String = "Quit Bento") {
        self.title = title
    }

    public var body: some View {
        Button(action: { NSApp.terminate(nil) }) {
            Label(title, systemImage: "power")
        }
        .keyboardShortcut("q")
    }
}
#endif
