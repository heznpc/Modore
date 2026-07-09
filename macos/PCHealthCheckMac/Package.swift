// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PCHealthCheckMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PCHealthCheckMac", targets: ["PCHealthCheckMac"])
    ],
    targets: [
        .executableTarget(
            name: "PCHealthCheckMac",
            path: "Sources/PCHealthCheckMac"
        )
    ]
)
