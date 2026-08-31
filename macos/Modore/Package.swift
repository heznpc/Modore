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
    dependencies: [
        .package(path: "../../shared/ModoreDomain"),
        .package(path: "../../vendor/mothball")
    ],
    targets: [
        .executableTarget(
            name: "Modore",
            dependencies: [
                .product(name: "ModoreDomain", package: "ModoreDomain"),
                .product(name: "MothballCore", package: "mothball")
            ],
            path: "Sources/Modore"
        ),
        .testTarget(
            name: "ModoreTests",
            dependencies: [
                "Modore",
                .product(name: "ModoreDomain", package: "ModoreDomain"),
            ],
            path: "Tests/ModoreTests"
        )
    ]
)
