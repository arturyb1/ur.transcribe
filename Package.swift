// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "URTranscribe",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "URTranscribe",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/URTranscribe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "URTranscribeTests",
            dependencies: ["URTranscribe"],
            path: "Tests/URTranscribeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
