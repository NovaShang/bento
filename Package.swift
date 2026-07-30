// swift-tools-version: 5.10
import PackageDescription

// THE package, rooted at the repo: modules/ is one directory per module —
// that listing IS the module map (docs/architecture.md) — and every Swift
// test lives under tests/. SPM enforces the dependency arrows below; an
// illegal import is a build error, not a review comment. Cross-module
// access is `package`-level unless genuinely app-facing.
//
// The four app shells in apps/ consume products from here.

// GhosttyKit is libghostty as an xcframework (MIT-Ghostty build with the
// external-backend patch; replace with our own vendored build before GA).
let ghosttyKit: Target = .binaryTarget(
    name: "GhosttyKit",
    url: "https://github.com/arach/TermBridgeKit/releases/download/0.1.5/GhosttyKit.xcframework.zip",
    checksum: "d9246242185d9ce5d4ee45fb0ff3fbc520aa995641dea9b198e43e1e4538b759"
)

// System frameworks the static libghostty needs to link.
let ghosttyLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("CoreText"),
    .linkedFramework("Metal"),
    .linkedFramework("AppKit", .when(platforms: [.macOS])),
    .linkedFramework("Carbon", .when(platforms: [.macOS])),
    .linkedFramework("UIKit", .when(platforms: [.iOS])),
    .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
]

let package = Package(
    name: "BentoModules",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // The umbrella product A's apps link (`import BentoCore` re-exports
        // the trunk). Never contains the terminal/tmux panes — libghostty
        // must not ride into the agent-only apps.
        .library(name: "BentoCore", targets: ["BentoCore"]),
        // Narrow products for direct consumers (product-B shells, tools).
        .library(name: "ACPKit", targets: ["ACPKit"]),
        .library(name: "BentoLink", targets: ["BentoLink"]),
        .library(name: "BentoFoundation", targets: ["BentoFoundation"]),
        .library(name: "BentoUI", targets: ["BentoUI"]),
        .library(name: "BentoVoiceKit", targets: ["BentoVoiceKit"]),
        .library(name: "BentoFilePreviewKit", targets: ["BentoFilePreviewKit"]),
        .library(name: "BentoWorkbench", targets: ["BentoWorkbench"]),
        .library(name: "SwiftTmux", targets: ["SwiftTmux"]),
        .library(name: "BentoTermLink", targets: ["BentoTermLink"]),
        .library(name: "BentoTerminalPane", targets: ["BentoTerminalPane"]),
        .library(name: "BentoTmuxPane", targets: ["BentoTmuxPane"]),
        .library(name: "BentoAgentPane", targets: ["BentoAgentPane"]),
        .library(name: "BentoShelliOS", targets: ["BentoShelliOS"]),
        .library(name: "BentoShellMac", targets: ["BentoShellMac"]),
        .library(name: "BentoShellTermMac", targets: ["BentoShellTermMac"]),
        .library(name: "BentoMenuKit", targets: ["BentoMenuKit"]),
        .executable(name: "acp-probe", targets: ["ACPProbe"]),
        .executable(name: "acp-host-probe", targets: ["AcpHostProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        // iOS's SSH client. macOS spawns the system `ssh` instead (see
        // BentoTermLink) — this is only for the platform that has no binary to
        // spawn and no way to fork.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
    ],
    targets: [
        // ── protocol & link ──
        .target(name: "ACPKit", path: "modules/ACPKit"),
        // BentoLink → ACPKit is deliberate and final: the sealed transport
        // engine (AcpHostTransport) lives here and implements ACPKit's
        // ACPTransport. BentoLink is the transport; ACPKit stays a
        // protocol-only peer with no dependencies of its own.
        .target(
            name: "BentoLink",
            dependencies: ["ACPKit"],
            path: "modules/BentoLink"
        ),

        // ── ground floor ──
        .target(
            name: "BentoFoundation",
            path: "modules/BentoFoundation"
        ),
        .target(
            name: "BentoUI",
            dependencies: ["BentoFoundation"],
            path: "modules/BentoUI"
        ),

        // ── capabilities ──
        .target(
            name: "BentoVoiceKit",
            dependencies: ["BentoFoundation", "BentoUI"],
            path: "modules/BentoVoiceKit"
        ),
        .target(
            name: "BentoFilePreviewKit",
            dependencies: ["BentoFoundation", "BentoUI", "BentoLink"],
            path: "modules/BentoFilePreviewKit",
            resources: [.copy("Resources/PathPreview")]
        ),

        // ── the workbench (seams live here; may not import any pane) ──
        .target(
            name: "BentoWorkbench",
            dependencies: ["BentoFoundation", "BentoUI", "ACPKit", "BentoLink"],
            path: "modules/BentoWorkbench"
        ),

        // ── the tmux protocol ──
        // Control-mode framing, command building, and the structure snapshot,
        // parsed CLIENT-side. Zero dependencies on purpose: the parser is the
        // one thing both a Mac pty and an iOS SSH channel feed, and it must not
        // know which. (Restored from the pre-merge terminal product; the Go
        // port in daemon/internal/tmuxcm stays for Agents' future terminal
        // pane.)
        .target(name: "SwiftTmux", path: "modules/SwiftTmux"),

        // ── the byte channel to a shell ──
        // A `TerminalTransport` is "bytes in, bytes out, and a size" — a local
        // pty on macOS (which, given an `ssh …` command, is also how the Mac
        // reaches a remote host: the system binary brings ~/.ssh/config,
        // ProxyJump and the agent with it) or an in-process Citadel client on
        // iOS, where there is no binary to spawn. Nothing above this layer
        // knows which one it got. Not tmux-specific, despite the name's
        // product association.
        .target(
            name: "BentoTermLink",
            dependencies: [
                "BentoFoundation", "BentoFilePreviewKit",
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "modules/BentoTermLink"
        ),

        // ── panes ──
        ghosttyKit,
        .target(
            name: "BentoTerminalPane",
            dependencies: ["GhosttyKit"],
            path: "modules/BentoTerminalPane",
            linkerSettings: ghosttyLinkerSettings
        ),
        // Product B's pane content: tmux virtual instances rendered on the
        // terminal base. NEVER a BentoCore dependency — libghostty must not
        // ride into product A. ACPKit appears here only because PaneRuntime's
        // establishment face still names two ACP types (see the header note
        // in TmuxPaneRuntime.swift); no ACP semantics are used.
        .target(
            name: "BentoTmuxPane",
            dependencies: [
                "BentoTerminalPane", "BentoWorkbench", "BentoLink",
                "BentoUI", "BentoFoundation", "ACPKit",
            ],
            path: "modules/BentoTmuxPane"
        ),
        .target(
            name: "BentoAgentPane",
            dependencies: [
                "BentoWorkbench", "BentoFoundation", "BentoUI",
                "BentoVoiceKit", "BentoFilePreviewKit", "ACPKit", "BentoLink",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "modules/BentoAgentPane",
            resources: [.copy("Resources/ProviderIcons")]
        ),

        // ── shells ──
        // Product A + B's shared iOS/iPad workspace shell: WorkspaceScreen,
        // the tiled pane container + chrome, the voice trio, pairing/host-list,
        // SessionManager. Generic over pane kind — it names no ACP or tmux
        // type; the app composition root registers the pane-VC factory
        // (ShellPaneRegistry) and the store provider. Deliberately NOT a
        // BentoAgentPane consumer (docs/term-ios-port.md §1): both iOS apps
        // stop drifting by sharing this. UIKit code is `canImport(UIKit)`
        // guarded so it compiles to nothing on the macOS host `swift build`.
        .target(
            name: "BentoShelliOS",
            dependencies: [
                "BentoWorkbench", "BentoVoiceKit", "BentoFilePreviewKit",
                "BentoUI", "BentoFoundation", "BentoLink",
            ],
            path: "modules/BentoShelliOS"
        ),
        .target(
            name: "BentoShellMac",
            dependencies: [
                "BentoWorkbench", "BentoAgentPane", "BentoVoiceKit",
                "BentoFilePreviewKit", "BentoUI", "BentoFoundation",
            ],
            path: "modules/BentoShellMac"
        ),
        // Product B's AppKit shell — the sibling of BentoShellMac, on the tmux
        // pane instead of the ACP pane. Deliberately NOT a BentoAgentPane /
        // MarkdownUI consumer (per-product shells; docs/term-shell-port.md §2.1):
        // the tmux tower is all it renders.
        .target(
            name: "BentoShellTermMac",
            dependencies: [
                "BentoWorkbench", "BentoTmuxPane", "BentoTerminalPane",
                "BentoVoiceKit", "BentoFilePreviewKit", "BentoUI",
                "BentoFoundation", "BentoLink",
            ],
            path: "modules/BentoShellTermMac"
        ),

        // ── the host's menu bar ──
        // HOST-scoped, not product-scoped: the daemon status model + CLI
        // wrapper, the menu-bar rows that describe or control the ONE
        // bento-daemon both Mac products share, and the URL router that a
        // resident menu process uses to launch them
        // (docs/menubar-unification.md). The absence of BentoAgentPane /
        // BentoTmuxPane / either Mac shell from this list is the invariant:
        // nothing product-scoped may leak in, or the eventual BentoMenu.app
        // would have to link a product to draw a menu.
        .target(
            name: "BentoMenuKit",
            dependencies: ["BentoFoundation"],
            path: "modules/BentoMenuKit"
        ),

        // ── umbrella ──
        .target(
            name: "BentoCore",
            dependencies: [
                "BentoFoundation", "BentoUI", "BentoVoiceKit",
                "BentoFilePreviewKit", "BentoWorkbench", "BentoAgentPane",
                "BentoShellMac",
            ],
            path: "modules/BentoCore"
        ),

        // ── probes ──
        .executableTarget(
            name: "ACPProbe",
            dependencies: ["ACPKit"],
            path: "tools/ACPProbe"
        ),
        .executableTarget(
            name: "AcpHostProbe",
            dependencies: ["ACPKit", "BentoFoundation", "BentoLink", "BentoWorkbench"],
            path: "tools/AcpHostProbe"
        ),

        // ── tests (all of them live in tests/) ──
        .testTarget(
            name: "ACPKitTests",
            dependencies: ["ACPKit"],
            path: "tests/ACPKitTests"
        ),
        .testTarget(
            name: "BentoLinkTests",
            dependencies: ["BentoLink"],
            path: "tests/BentoLinkTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "BentoCoreTests",
            dependencies: ["BentoCore"],
            path: "tests/BentoCoreTests"
        ),
        .testTarget(
            name: "SwiftTmuxTests",
            dependencies: ["SwiftTmux"],
            path: "tests/SwiftTmuxTests"
        ),
        .testTarget(
            name: "BentoTerminalPaneTests",
            dependencies: ["BentoTerminalPane"],
            path: "tests/BentoTerminalPaneTests"
        ),
        .testTarget(
            name: "BentoTmuxPaneTests",
            dependencies: ["BentoTmuxPane", "BentoWorkbench", "BentoTerminalPane"],
            path: "tests/BentoTmuxPaneTests"
        ),
        .testTarget(
            name: "BentoShellTermMacTests",
            dependencies: [
                "BentoShellTermMac", "BentoTmuxPane", "BentoWorkbench",
                "BentoTerminalPane",
            ],
            path: "tests/BentoShellTermMacTests"
        ),
        .testTarget(
            name: "BentoMenuKitTests",
            dependencies: ["BentoMenuKit"],
            path: "tests/BentoMenuKitTests"
        ),
    ]
)
