// swift-tools-version: 5.10
import PackageDescription

// GhosttyKit is the libghostty C library packaged as an xcframework — the
// same prebuilt MIT-Ghostty build bento-terminal-core consumes (see that
// manifest's note about replacing it with our own build before shipping).
// Declared identically here so the two packages render with the same engine
// for as long as both exist.
let ghosttyKit: Target = .binaryTarget(
    name: "GhosttyKit",
    url: "https://github.com/arach/TermBridgeKit/releases/download/0.1.5/GhosttyKit.xcframework.zip",
    checksum: "d9246242185d9ce5d4ee45fb0ff3fbc520aa995641dea9b198e43e1e4538b759"
)

// System frameworks the static libghostty needs to link.
let coreLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("CoreText"),
    .linkedFramework("Metal"),
    .linkedFramework("AppKit", .when(platforms: [.macOS])),
    .linkedFramework("Carbon", .when(platforms: [.macOS])),
    .linkedFramework("UIKit", .when(platforms: [.iOS])),
    .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
]

// The terminal RENDERING base, extracted from the frozen bento-terminal-core
// (which keeps its own copy until the terminal product retires — the same
// duality as desktop-term/). Both the pty pane and the coming tmux pane link
// this; neither product's shell chrome lives here. Deliberately depends on
// GhosttyKit alone: everything workspace-, preview-, or theme-store-shaped is
// injected by the host through constructor parameters and callbacks (see the
// module-map note at the top of TerminalSurface.swift).
let package = Package(
    name: "BentoTerminalPane",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BentoTerminalPane", targets: ["BentoTerminalPane"]),
    ],
    targets: [
        ghosttyKit,
        .target(
            name: "BentoTerminalPane",
            dependencies: ["GhosttyKit"],
            linkerSettings: coreLinkerSettings
        ),
        .testTarget(
            name: "BentoTerminalPaneTests",
            dependencies: ["BentoTerminalPane"]
        ),
    ]
)
