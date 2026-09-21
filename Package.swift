// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeridianStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProjectModel", targets: ["ProjectModel"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .executable(name: "MeridianStudioApp", targets: ["MeridianStudioApp"])
    ],
    targets: [
        .target(name: "ProjectModel"),
        .target(name: "AudioEngine", dependencies: ["ProjectModel"]),
        .executableTarget(name: "MeridianStudioApp", dependencies: ["ProjectModel", "AudioEngine"]),
        .testTarget(name: "ProjectModelTests", dependencies: ["ProjectModel"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine", "ProjectModel"])
    ]
)
