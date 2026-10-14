// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Fetch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Fetch", targets: ["FetchApp"]), .executable(name: "FetchProbe", targets: ["FetchProbe"])],
    targets: [
        .target(name: "FetchCore"),
        .executableTarget(name: "FetchApp", dependencies: ["FetchCore"]),
        .executableTarget(name: "FetchProbe", dependencies: ["FetchCore"]),
        .testTarget(name: "FetchCoreTests", dependencies: ["FetchCore"])
    ],
    swiftLanguageModes: [.v5]
)
