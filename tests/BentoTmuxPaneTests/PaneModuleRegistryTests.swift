import XCTest
import BentoTerminalPane
import BentoUI
import BentoWorkbench
@testable import BentoTmuxPane
#if os(macOS)
import AppKit
#endif

/// The pane-module registry (seam one's registration point) and PaneKind's
/// wire compatibility: opening the kind up to a string-backed registry key
/// must leave the persisted field byte-identical ("acp", decode-default
/// included) — that blob is mirrored into the daemon's statekv and read by
/// other devices.
@MainActor
final class PaneModuleRegistryTests: XCTestCase {
    private static let persistKey = "tmuxpane_registry_test"
    private var store: AgentWorkspaceStore!

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
        store = AgentWorkspaceStore(persistKey: Self.persistKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
    }

    // MARK: - PaneKind wire compatibility

    func testPaneKindEncodesAsBareString() throws {
        let json = try JSONEncoder().encode([PaneKind.acp, .tmux])
        XCTAssertEqual(String(decoding: json, as: UTF8.self), #"["acp","tmux"]"#)
    }

    func testPaneEntryStillEncodesKindAcp() throws {
        let entry = AgentWorkspaceStore.PaneEntry(
            id: 1, presetID: "p", customPreset: nil, cwd: "/tmp", title: nil,
            instanceID: nil, acpSessionID: nil, startCommand: nil)
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        XCTAssertTrue(json.contains(#""kind":"acp""#), "wire shape drifted: \(json)")
    }

    func testKindlessEntryDecodesAsAcp() throws {
        let entry = try JSONDecoder().decode(
            AgentWorkspaceStore.PaneEntry.self,
            from: Data(#"{"id":1,"presetID":"p","cwd":"/tmp"}"#.utf8))
        XCTAssertEqual(entry.kind, .acp)
    }

    func testUnknownKindSurvivesDecode() throws {
        // The closed enum would have thrown here and taken the whole
        // persisted state with it; the open kind rides through.
        let entry = try JSONDecoder().decode(
            AgentWorkspaceStore.PaneEntry.self,
            from: Data(#"{"id":1,"kind":"pty","presetID":"p","cwd":"/tmp"}"#.utf8))
        XCTAssertEqual(entry.kind, PaneKind(rawValue: "pty"))
    }

    func testStorePaneKindDefaultsToAcp() {
        store.createSession("work")
        let paneID = store.paneList(session: "work")[0].id.raw
        XCTAssertEqual(store.paneKind(paneID), .acp)
        XCTAssertEqual(store.paneKind(999_999), .acp)   // unknown pane
    }

    // MARK: - Registry dispatch

    #if os(macOS)
    private final class FakeSurfaceView: NSView {}

    private final class FakePaneModule: PaneModule {
        let kind = PaneKind(rawValue: "fake")
        let capabilities: PaneCapabilities = [.textInput]
        var made: [PaneID] = []
        let view = FakeSurfaceView()
        func makeSurface(for pane: PaneID, in store: AgentWorkspaceStore,
                         theme: CanvasTheme) -> PaneSurfaceView {
            made.append(pane)
            return view
        }
    }

    func testRegistryDispatchesOnPersistedKind() {
        let registry = PaneModuleRegistry()
        let fake = FakePaneModule()
        registry.register(fake)

        store.createSession("work")
        let paneID = store.paneList(session: "work")[0].id
        let theme = CanvasTheme(background: 0x000000, foreground: 0xFFFFFF)

        // An .acp pane finds no module in this registry → nil, which is the
        // Mac host's cue to fall back to its own ACP construction.
        XCTAssertNil(registry.makeSurface(for: paneID, in: store, theme: theme))

        // Flip the pane's kind: the same call now lands in the fake module —
        // the makeCell-equivalent path, minus AppKit hosting.
        store.state.sessions[0].panes[0].kind = fake.kind
        let surface = registry.makeSurface(for: paneID, in: store, theme: theme)
        XCTAssertTrue(surface === fake.view)
        XCTAssertEqual(fake.made, [paneID])
    }

    func testLastRegistrationWins() {
        let registry = PaneModuleRegistry()
        let first = FakePaneModule()
        let second = FakePaneModule()
        registry.register(first)
        registry.register(second)
        XCTAssertTrue(registry.module(for: first.kind) === second)
    }
    #endif

    // MARK: - The tmux module's registry face

    func testTmuxModuleIdentityAndCapabilities() {
        let module = TmuxPaneModule { _ in InMemoryTmuxTransport() }
        XCTAssertEqual(module.kind, .tmux)
        XCTAssertTrue(module.capabilities.contains(.hostedProcess))
        XCTAssertTrue(module.capabilities.contains(.textInput))
        XCTAssertTrue(module.capabilities.contains(.resizable))
        XCTAssertFalse(module.capabilities.contains(.fileScoped))
    }

    func testInstallRegistersAndBuildsAttachedRuntimes() async {
        let registry = PaneModuleRegistry()
        let transport = InMemoryTmuxTransport()
        let module = TmuxPaneModule.install(on: store, registry: registry) { _ in transport }
        XCTAssertTrue(registry.module(for: .tmux) === module)

        let runtime = module.makeRuntime(
            paneID: 1, instanceRaw: "tmux:local:%5", title: "zsh",
            command: "zsh", store: store)
        XCTAssertEqual(runtime.instanceID.raw, "tmux:local:%5")
        XCTAssertEqual(runtime.currentCommand, "zsh")
        let deadline = Date().addingTimeInterval(2)
        while runtime.phase != .ready, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(runtime.phase, .ready)          // attach was kicked
        XCTAssertEqual(transport.attaches, [0])
        runtime.shutdown()
    }

    func testRuntimeWithoutInstanceIDComesUpFailed() {
        let module = TmuxPaneModule { _ in InMemoryTmuxTransport() }
        let runtime = module.makeRuntime(
            paneID: 4, instanceRaw: nil, title: nil, command: nil, store: store)
        guard case .failed = runtime.phase else {
            return XCTFail("expected .failed, got \(runtime.phase)")
        }
    }
}
