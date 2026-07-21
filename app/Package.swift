// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenWatch",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.2.4"),
    ],
    targets: [
        .executableTarget(
            name: "TokenWatch",
            path: "Sources/TokenWatch",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "TokenWatchTests",
            dependencies: [
                "TokenWatch",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/TokenWatchTests"
        ),
    ]
)
