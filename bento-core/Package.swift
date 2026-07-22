// swift-tools-version: 5.10
import PackageDescription

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
        .target(
            name: "BentoCore",
            dependencies: [
                .product(name: "ACPKit", package: "acpkit"),
                .product(name: "ACPHostKit", package: "acpkit"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            resources: [
                // File-preview web renderer: template + vendored highlight.js
                // and markdown-it (see Resources/PathPreview/LICENSES.txt).
                .copy("Resources/PathPreview"),
                // Brand logos for the first-class providers' connect cards
                // (Simple Icons / svgl marks, rasterized).
                .copy("Resources/ProviderIcons"),
            ]
        ),
        .testTarget(
            name: "BentoCoreTests",
            dependencies: ["BentoCore"]
        ),
    ]
)
