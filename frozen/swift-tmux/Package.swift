// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftTmux",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SwiftTmux",
            targets: ["SwiftTmux"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftTmux"
        ),
        .testTarget(
            name: "SwiftTmuxTests",
            dependencies: ["SwiftTmux"]
        ),
    ]
)
