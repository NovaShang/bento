import BentoFoundation
import BentoTerminalPane
import BentoUI
import BentoWorkbench
import Foundation

/// The tmux pane's module entry: registry identity, the terminal surface
/// factory (macOS; iOS rides the stage-2 shell port), and the store
/// install that builds `TmuxPaneRuntime`s over a `TmuxByteTransport`.
///
/// This is the third row of "three pane kinds diverge only at L4": the
/// store steers a tmux pane through the same `PaneRuntime` verbs as an ACP
/// agent; only this module knows the content is a terminal.
@MainActor
public final class TmuxPaneModule: PaneModule {
    public let kind: PaneKind = .tmux
    public let capabilities: PaneCapabilities = [.hostedProcess, .textInput, .resizable]

    /// Builds the byte pipe for one virtual instance. The BentoLink-backed
    /// factory is stage-2 (it lands with the daemon's wire shapes);
    /// `InMemoryTmuxTransport` stands in for tests and previews.
    public typealias TransportFactory =
        @MainActor (_ instance: TmuxVirtualInstanceID) -> any TmuxByteTransport

    private let makeTransport: TransportFactory

    /// Terminal text size for surfaces this module builds; the term
    /// shell's settings own it once that shell exists.
    public var fontSize: Double = 13

    /// Whether this module's panes ride a local pipe. Not cosmetic — it picks
    /// the seed depth below, which is the difference between an instant attach
    /// and a stalled one on a phone.
    public var isLocalLink = true

    /// How far back a fresh surface is seeded from tmux's history, in lines.
    ///
    /// This used to be one screenful, which meant a pane's scrollback
    /// effectively began the moment its surface was created — and surfaces are
    /// recreated whenever the pane set changes, so **every window switch threw
    /// the scrollback away**. Nothing that reads backwards worked past that
    /// line: scrolling up, turn navigation, ⌘F.
    ///
    /// tmux clamps `-S` to whatever history actually exists, so this is a
    /// ceiling, not a cost floor. 2000 = tmux's own default `history-limit`,
    /// over a local pty where the capture is a pipe read.
    ///
    /// Over a network link it is a very different bill: the same capture is
    /// decrypted and drained on the main thread (iOS does all of that there),
    /// it is paid again on every window switch, and `escapes: true` inflates a
    /// colorful agent pane several-fold. So a remote link seeds a few screens —
    /// enough that scrolling back still finds something, not enough to stall an
    /// attach on a phone. The two tiers ARE the conclusion; do not average them.
    /// Override without a rebuild via `terminal_seed_history_lines`.
    public var seedHistoryLines: Int {
        let configured = UserDefaults.standard.integer(forKey: "terminal_seed_history_lines")
        if configured > 0 { return configured }
        return isLocalLink ? 2000 : 400
    }

    public init(makeTransport: @escaping TransportFactory) {
        self.makeTransport = makeTransport
    }

    /// Wire this module into a store: register in the module table and
    /// install the runtime factory. The store must stay `launcher`-less —
    /// its launcher ladder is ACP-shaped and a tmux pane establishes
    /// through `TmuxPaneRuntime.attach()` (kicked here); routing the
    /// ladder by capability is the flagged stage-2 seam.
    @discardableResult
    public static func install(on store: AgentWorkspaceStore,
                               registry: PaneModuleRegistry = .shared,
                               makeTransport: @escaping TransportFactory) -> TmuxPaneModule {
        let module = TmuxPaneModule(makeTransport: makeTransport)
        registry.register(module)
        store.runtimeFactory = { [unowned store] paneID, entry, _ in
            module.makeRuntime(paneID: paneID, instanceRaw: entry.instanceID,
                               title: entry.title, command: entry.startCommand,
                               store: store)
        }
        return module
    }

    /// One pane's runtime. A pane record without a parseable virtual id
    /// (the projection always writes one) comes up failed rather than
    /// half-alive.
    func makeRuntime(paneID: Int, instanceRaw: String?, title: String?,
                     command: String?, store: AgentWorkspaceStore) -> TmuxPaneRuntime {
        guard let raw = instanceRaw, let instance = TmuxVirtualInstanceID(raw: raw) else {
            let runtime = TmuxPaneRuntime(
                instanceID: TmuxVirtualInstanceID(target: "local", pane: TmuxPaneID(paneID)),
                title: title ?? "",
                transport: InMemoryTmuxTransport())
            runtime.noteLaunchFailure("pane has no tmux instance id (\(instanceRaw ?? "nil"))")
            return runtime
        }
        let transport = makeTransport(instance)
        let runtime = TmuxPaneRuntime(
            instanceID: instance,
            title: title ?? "",
            transport: transport)
        // Wired HERE, not by each shell: while this was the shell's job only
        // macOS ever did it, so every iOS pane opened blank. It must also be in
        // place before any surface binds — a source wired afterwards arrives
        // too late and the pane sits blank until its next repaint.
        runtime.captureScrollback = { [weak self] in
            await transport.captureScrollback(lines: self?.seedHistoryLines ?? 400)
        }
        runtime.currentCommand = command
        runtime.onActivityChange = { [weak store] in
            store?.emit(.activity(pane: paneID))
        }
        runtime.attach()
        return runtime
    }

    // Surface factory + byte binding are platform-neutral (the engine surface,
    // the coalescer, and the runtime are all cross-platform); iOS embeds the
    // returned surface inside the term shell's pane VC, macOS inside its cell.
    #if os(macOS) || canImport(UIKit)
    public func makeSurface(for pane: PaneID, in store: AgentWorkspaceStore,
                            theme: CanvasTheme) -> PaneSurfaceView {
        let surface = GhosttyTerminalSurface(theme: terminalTheme(from: theme))
        if let runtime = store.runtime(forPane: pane.raw) as? TmuxPaneRuntime {
            bind(surface, to: runtime)
        }
        return surface
    }

    /// Byte streams both ways plus the renderer-authoritative resize —
    /// the whole surface ↔ runtime contract. Input rides `TmuxInputCoalescer`
    /// (the 178690d shell-half): keystrokes flush leading-edge + 16 ms-trailing
    /// off the main actor, so a paste or key-repeat burst never stalls typing.
    /// The coalescer lives on the surface's `onInput` closure — it is released
    /// when the surface tears down.
    func bind(_ surface: GhosttyTerminalSurface, to runtime: TmuxPaneRuntime) {
        runtime.onOutput = { [weak surface] data in surface?.feed(data) }
        // A fresh surface holds NO history for this pane — the first open, and
        // every re-bind after a window switch tore the old one down. tmux does
        // not repaint static content for a new client, so without this the pane
        // shows whatever the program next happens to redraw and nothing else.
        // Both shells reach the seed through this one call.
        runtime.seedFromCapture()
        let coalescer = TmuxInputCoalescer { [weak runtime] data in runtime?.writeRaw(data) }
        surface.onInput = { data in coalescer.send(data) }
        surface.onSizeChanged = { [weak runtime] size in
            runtime?.resize(cols: size.columns, rows: size.rows)
        }
    }

    /// The pane canvas carries only bg/fg; ANSI palette and cursor come
    /// from the shared terminal theme table until the term shell's
    /// settings arrive.
    func terminalTheme(from canvas: CanvasTheme) -> TerminalTheme {
        let dark = Self.isDark(background: canvas.background)
        let fallback = TerminalColorTheme.builtIn.first { $0.isDark == dark }
            ?? TerminalColorTheme.builtIn[0]
        return TerminalTheme(
            background: canvas.background,
            foreground: canvas.foreground,
            ansi: fallback.ansi,
            fontSize: fontSize,
            isDark: dark)
    }

    /// Relative luminance below ½ reads as dark — the same judgement the
    /// engine needs for OSC 2031 / DSR ?996 answers.
    static func isDark(background: UInt32) -> Bool {
        let r = Double((background >> 16) & 0xFF) / 255
        let g = Double((background >> 8) & 0xFF) / 255
        let b = Double(background & 0xFF) / 255
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.5
    }
    #endif
}
