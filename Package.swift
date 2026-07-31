// swift-tools-version: 5.10
import PackageDescription

// THE package, rooted at the repo: modules/ is one directory per module —
// that listing IS the module map (docs/architecture.md) — and every Swift
// test lives under tests/. SPM enforces the dependency arrows below; an
// illegal import is a build error, not a review comment. Cross-module
// access is `package`-level unless genuinely app-facing.
//
// The two app shells in apps/ consume products from here.

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
        // The umbrella the apps link (`import BentoCore` re-exports the
        // trunk). Carries no terminal pane: libghostty is a heavy binary
        // dependency and the chat-only apps must not link it just to exist.
        // A shell that wants a terminal pane names BentoTerminalPane itself.
        .library(name: "BentoCore", targets: ["BentoCore"]),
        // Narrow products for direct consumers (shells, tools).
        .library(name: "ACPKit", targets: ["ACPKit"]),
        .library(name: "BentoLink", targets: ["BentoLink"]),
        .library(name: "BentoFoundation", targets: ["BentoFoundation"]),
        .library(name: "BentoUI", targets: ["BentoUI"]),
        .library(name: "BentoVoiceKit", targets: ["BentoVoiceKit"]),
        .library(name: "BentoFilePreviewKit", targets: ["BentoFilePreviewKit"]),
        .library(name: "BentoWorkbench", targets: ["BentoWorkbench"]),
        .library(name: "BentoTerminalPane", targets: ["BentoTerminalPane"]),
        .library(name: "BentoAgentPane", targets: ["BentoAgentPane"]),
        .library(name: "BentoShellMac", targets: ["BentoShellMac"]),
        .library(name: "BentoMenuKit", targets: ["BentoMenuKit"]),
        .executable(name: "acp-probe", targets: ["ACPProbe"]),
        .executable(name: "acp-host-probe", targets: ["AcpHostProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
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
            // No BentoLink: the preview CORE is a protocol plus a renderer, and
            // the sources that satisfy it belong to whoever owns the wire — the
            // daemon-backed one moved to BentoAgentPane, the SFTP one lives in
            // BentoTermLink. Keeping the ACP stack out of here is what keeps it
            // out of every Bento Term module, which reaches nothing but SSH.
            dependencies: ["BentoFoundation", "BentoUI"],
            path: "modules/BentoFilePreviewKit",
            resources: [.copy("Resources/PathPreview")]
        ),

        // ── the workbench (seams live here; may not import any pane) ──
        .target(
            name: "BentoWorkbench",
            dependencies: ["BentoFoundation", "BentoUI", "ACPKit", "BentoLink"],
            path: "modules/BentoWorkbench"
        ),

        // ── panes ──
        // Every pane kind is a module that registers itself through
        // BentoWorkbench's `PaneModule` seam. The workbench names no pane
        // type and no shell hardcodes one, which is what lets a terminal /
        // file editor / browser pane land without rewiring anything.
        ghosttyKit,
        // The terminal rendering base: libghostty embedded, surface +
        // selection + mouse reporting + output-driven state detection. Not
        // yet wired into a pane module — kept building so it can't rot before
        // the ghostty pane lands. NEVER a BentoCore dependency: libghostty
        // must not ride into apps that show no terminal.
        .target(
            name: "BentoTerminalPane",
            dependencies: ["GhosttyKit"],
            path: "modules/BentoTerminalPane",
            linkerSettings: ghosttyLinkerSettings
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
        .target(
            name: "BentoShellMac",
            dependencies: [
                "BentoWorkbench", "BentoAgentPane", "BentoVoiceKit",
                "BentoFilePreviewKit", "BentoUI", "BentoFoundation",
            ],
            path: "modules/BentoShellMac"
        ),

        // ── the host's menu bar ──
        // HOST-scoped, not product-scoped: the daemon status model + CLI
        // wrapper, the menu-bar rows that describe or control the ONE
        // bento-daemon both Mac products share, and the URL router that a
        // resident menu process uses to launch them
        // (docs/menubar-unification.md). The absence of BentoAgentPane and of
        // the Mac shell from this list is the invariant: nothing pane- or
        // window-scoped may leak in, or the eventual BentoMenu.app would have
        // to link the whole app to draw a menu.
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
            name: "BentoTerminalPaneTests",
            dependencies: ["BentoTerminalPane"],
            path: "tests/BentoTerminalPaneTests"
        ),
        .testTarget(
            name: "BentoMenuKitTests",
            dependencies: ["BentoMenuKit"],
            path: "tests/BentoMenuKitTests"
        ),
    ]
)
