// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ModoreDomain",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "ModoreDomain", targets: ["ModoreDomain"]),
    ],
    targets: [
        .target(name: "ModoreDomain"),
        .testTarget(
            name: "ModoreDomainTests",
            dependencies: ["ModoreDomain"]
        ),
    ]
)
