// swift-tools-version: 5.10
import PackageDescription

// THE package, rooted at the repo: modules/ is one directory per module —
// that listing IS the module map (docs/architecture.md) — and every Swift
// test lives under tests/. SPM enforces the dependency arrows below; an
// illegal import is a build error, not a review comment. Cross-module
// access is `package`-level unless genuinely app-facing.
//
// The four app shells in apps/ consume products from here; the frozen
// terminal product in frozen/ keeps its own packages until P7 retires it.

// GhosttyKit is libghostty as an xcframework (MIT-Ghostty build with the
// external-backend patch; see the vendoring note in the frozen manifest).
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
        .library(name: "ACPHostKit", targets: ["ACPHostKit"]),
        .library(name: "BentoFoundation", targets: ["BentoFoundation"]),
        .library(name: "BentoUI", targets: ["BentoUI"]),
        .library(name: "BentoVoiceKit", targets: ["BentoVoiceKit"]),
        .library(name: "BentoFilePreviewKit", targets: ["BentoFilePreviewKit"]),
        .library(name: "BentoWorkbench", targets: ["BentoWorkbench"]),
        .library(name: "BentoTerminalPane", targets: ["BentoTerminalPane"]),
        .library(name: "BentoAgentPane", targets: ["BentoAgentPane"]),
        .library(name: "BentoShellMac", targets: ["BentoShellMac"]),
        .executable(name: "acp-probe", targets: ["ACPProbe"]),
        .executable(name: "acp-host-probe", targets: ["AcpHostProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        // ── protocol & link ──
        .target(name: "ACPKit", path: "modules/ACPKit"),
        .target(name: "BentoLink", path: "modules/BentoLink"),
        .target(
            name: "ACPHostKit",
            dependencies: ["ACPKit", "BentoLink"],
            path: "modules/ACPHostKit"
        ),

        // ── ground floor ──
        .target(
            name: "BentoFoundation",
            dependencies: ["ACPKit", "ACPHostKit"],
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
            dependencies: ["BentoFoundation", "BentoUI", "ACPKit", "ACPHostKit"],
            path: "modules/BentoFilePreviewKit",
            resources: [.copy("Resources/PathPreview")]
        ),

        // ── the workbench (seams live here; may not import any pane) ──
        .target(
            name: "BentoWorkbench",
            dependencies: ["BentoFoundation", "BentoUI", "ACPKit", "ACPHostKit"],
            path: "modules/BentoWorkbench"
        ),

        // ── panes ──
        ghosttyKit,
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
                "BentoVoiceKit", "BentoFilePreviewKit", "ACPKit", "ACPHostKit",
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
                "ACPKit", "ACPHostKit",
            ],
            path: "modules/BentoShellMac"
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
            path: "modules/ACPProbe"
        ),
        .executableTarget(
            name: "AcpHostProbe",
            dependencies: ["ACPKit", "ACPHostKit"],
            path: "modules/AcpHostProbe"
        ),

        // ── tests (all of them live in tests/) ──
        .testTarget(
            name: "ACPKitTests",
            dependencies: ["ACPKit"],
            path: "tests/ACPKitTests"
        ),
        .testTarget(
            name: "ACPHostKitTests",
            dependencies: ["ACPHostKit"],
            path: "tests/ACPHostKitTests",
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
    ]
)
