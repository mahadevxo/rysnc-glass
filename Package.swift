// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RsyncGlass",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "RsyncGlass",
            path: "Sources/RsyncGlass",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RsyncGlassTests",
            dependencies: ["RsyncGlass"],
            path: "Tests/RsyncGlassTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
