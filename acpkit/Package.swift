// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ACPKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ACPKit", targets: ["ACPKit"]),
        .library(name: "ACPHostKit", targets: ["ACPHostKit"]),
        .executable(name: "acp-probe", targets: ["ACPProbe"]),
        .executable(name: "acp-host-probe", targets: ["AcpHostProbe"]),
    ],
    targets: [
        .target(name: "ACPKit"),
        // Client side of the daemon's acphost protocol: sealed relay / local
        // unix-socket transports, launchers, agent presets. Split from ACPKit
        // so the pure-protocol layer stays dependency-free.
        .target(
            name: "ACPHostKit",
            dependencies: ["ACPKit"]
        ),
        .executableTarget(
            name: "ACPProbe",
            dependencies: ["ACPKit"]
        ),
        .executableTarget(
            name: "AcpHostProbe",
            dependencies: ["ACPKit", "ACPHostKit"]
        ),
        .testTarget(
            name: "ACPKitTests",
            dependencies: ["ACPKit"]
        ),
        .testTarget(
            name: "ACPHostKitTests",
            dependencies: ["ACPHostKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
