// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Modore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Modore", targets: ["Modore"])
    ],
    dependencies: [
        .package(path: "../../shared/ModoreDomain"),
        .package(path: "../../vendor/mothball"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.2.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .executableTarget(
            name: "Modore",
            dependencies: [
                .product(name: "ModoreDomain", package: "ModoreDomain"),
                .product(name: "MothballCore", package: "mothball"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/Modore",
            resources: [.process("Resources")]
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
