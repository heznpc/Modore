// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Modore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Modore", targets: ["Modore"])
    ],
    targets: [
        .executableTarget(
            name: "Modore",
            path: "Sources/Modore"
        ),
        .testTarget(
            name: "ModoreTests",
            dependencies: ["Modore"],
            path: "Tests/ModoreTests"
        )
    ]
)
