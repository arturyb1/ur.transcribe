// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Earshot",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "Earshot",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Earshot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EarshotTests",
            dependencies: ["Earshot"],
            path: "Tests/EarshotTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
