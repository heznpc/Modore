// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mothball",
    platforms: [.macOS(.v13)],
    // Library only. Mothball shipped as a standalone app until its
    // continuity work landed here; that app had no session binder, so
    // every archive it attempted was refused by the gate it now contains.
    // Modore builds this package for `MothballCore` alone -- the
    // executable target was already dead weight in the only build that
    // consumes it, and keeping a UI that cannot complete its one
    // destructive action is worse than not shipping it.
    products: [
        .library(name: "MothballCore", targets: ["MothballCore"]),
    ],
    targets: [
        .target(name: "MothballCore"),
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
