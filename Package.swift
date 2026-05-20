// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mothball",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MothballCore", targets: ["MothballCore"]),
        .executable(name: "Mothball", targets: ["MothballApp"]),
    ],
    targets: [
        .target(name: "MothballCore"),
        .executableTarget(
            name: "MothballApp",
            dependencies: ["MothballCore"]
        ),
        .testTarget(
            name: "MothballCoreTests",
            dependencies: ["MothballCore"]
        ),
    ]
)
