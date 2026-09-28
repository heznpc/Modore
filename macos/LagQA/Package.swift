// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "LagQA", platforms: [.macOS(.v13)], products: [
    .executable(name: "LagQA", targets: ["LagQA"])
], targets: [
    .executableTarget(name: "LagQA"),
    .testTarget(name: "LagQATests", dependencies: ["LagQA"])
])
