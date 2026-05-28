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
    ],
    // Pin language mode explicitly so a future tools-version bump or a
    // toolchain with a different default can't silently downgrade
    // strict-concurrency enforcement. The codebase is Sendable-clean
    // under v6; if that changes, this line forces the contributor to
    // make the regression explicit.
    swiftLanguageModes: [.v6]
)
