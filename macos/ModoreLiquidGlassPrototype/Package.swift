// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ModoreGlassPrototype",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ModoreGlassPrototype", targets: ["ModoreGlassPrototype"])],
    targets: [.executableTarget(name: "ModoreGlassPrototype")]
)
