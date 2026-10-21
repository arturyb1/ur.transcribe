// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "URTranscribe",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "URTranscribe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/URTranscribe",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle is a framework; the app bundle carries it in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "URTranscribeTests",
            dependencies: ["URTranscribe"],
            path: "Tests/URTranscribeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
