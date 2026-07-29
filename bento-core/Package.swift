// swift-tools-version: 5.10
import PackageDescription

// One package, seven modules, one umbrella. The targets ARE the module map
// (docs/architecture.md): SPM enforces the dependency arrows below at
// compile time, which is the whole point — an illegal import is a build
// error, not a review comment. Apps keep `import BentoCore` (the umbrella
// re-exports everything), so the split is invisible at the app layer.
//
// Cross-module access inside this package uses the `package` access level,
// never `public`, unless the symbol is genuinely app-facing API.

let package = Package(
    name: "BentoCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BentoCore", targets: ["BentoCore"]),
    ],
    dependencies: [
        .package(path: "../acpkit"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        // Ground floor: device identity, logging, telemetry, tips, the
        // agent CATALOG (scene-level: which agents exist, how to run them)
        // and the voice-sink vocabulary. Depends on nothing of ours.
        .target(
            name: "BentoFoundation",
            dependencies: [
                .product(name: "ACPKit", package: "acpkit"),
                .product(name: "ACPHostKit", package: "acpkit"),
            ]
        ),

        // Look: theme store, the pane state language's palette, shared
        // decorative views. No workspace knowledge.
        .target(
            name: "BentoUI",
            dependencies: ["BentoFoundation"]
        ),

        // Capability: speech in (capture, gate, engines, glass UI).
        .target(
            name: "BentoVoiceKit",
            dependencies: ["BentoFoundation", "BentoUI"]
        ),

        // Capability: file preview (web renderer, tree browser, sources).
        .target(
            name: "BentoFilePreviewKit",
            dependencies: [
                "BentoFoundation", "BentoUI",
                .product(name: "ACPKit", package: "acpkit"),
                .product(name: "ACPHostKit", package: "acpkit"),
            ],
            resources: [
                // File-preview web renderer: template + vendored highlight.js
                // and markdown-it (see Resources/PathPreview/LICENSES.txt).
                .copy("Resources/PathPreview"),
            ]
        ),

        // The workbench: workspace store, layout tree, view models, the two
        // seams (PaneRuntime, StructureAuthority), statekv sync. MUST NOT
        // import any pane module — that is seam one, and this manifest is
        // its enforcement.
        .target(
            name: "BentoWorkbench",
            dependencies: [
                "BentoFoundation", "BentoUI",
                .product(name: "ACPKit", package: "acpkit"),
                .product(name: "ACPHostKit", package: "acpkit"),
            ]
        ),

        // The ACP agent pane: runtime, transcript, chat UI, providers,
        // onboarding cards, and the Mac chat surface.
        .target(
            name: "BentoAgentPane",
            dependencies: [
                "BentoWorkbench", "BentoFoundation", "BentoUI",
                "BentoVoiceKit", "BentoFilePreviewKit",
                .product(name: "ACPKit", package: "acpkit"),
                .product(name: "ACPHostKit", package: "acpkit"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            resources: [
                // Brand logos for the first-class providers' connect cards
                // (Simple Icons / svgl marks, rasterized).
                .copy("Resources/ProviderIcons"),
            ]
        ),

        // The Mac shell: window, toolbar, tiled host, palette, docks.
        .target(
            name: "BentoShellMac",
            dependencies: [
                "BentoWorkbench", "BentoAgentPane", "BentoVoiceKit",
                "BentoFilePreviewKit", "BentoUI", "BentoFoundation",
                .product(name: "ACPKit", package: "acpkit"),
                .product(name: "ACPHostKit", package: "acpkit"),
            ]
        ),

        // Umbrella: re-exports every module so the apps' `import BentoCore`
        // keeps meaning what it always meant.
        .target(
            name: "BentoCore",
            dependencies: [
                "BentoFoundation", "BentoUI", "BentoVoiceKit",
                "BentoFilePreviewKit", "BentoWorkbench", "BentoAgentPane",
                "BentoShellMac",
            ]
        ),

        .testTarget(
            name: "BentoCoreTests",
            dependencies: ["BentoCore"]
        ),
    ]
)
