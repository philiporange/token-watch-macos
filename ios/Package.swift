// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenWatchCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TokenWatchCore", targets: ["TokenWatchCore"])],
    targets: [
        .target(name: "TokenWatchCore"),
        .testTarget(name: "TokenWatchCoreTests", dependencies: ["TokenWatchCore"]),
    ]
)
