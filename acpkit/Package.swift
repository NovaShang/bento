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
        .executable(name: "acp-probe", targets: ["ACPProbe"]),
    ],
    targets: [
        .target(name: "ACPKit"),
        .executableTarget(
            name: "ACPProbe",
            dependencies: ["ACPKit"]
        ),
        .testTarget(
            name: "ACPKitTests",
            dependencies: ["ACPKit"]
        ),
    ]
)
