// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeridianStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProjectModel", targets: ["ProjectModel"]),
        .library(name: "MIDIEngine", targets: ["MIDIEngine"]),
        .executable(name: "MeridianStudioApp", targets: ["MeridianStudioApp"])
    ],
    targets: [
        .target(name: "ProjectModel"),
        .target(name: "MIDIEngine", dependencies: ["ProjectModel"]),
        .executableTarget(name: "MeridianStudioApp", dependencies: ["ProjectModel", "MIDIEngine"]),
        .testTarget(name: "ProjectModelTests", dependencies: ["ProjectModel"]),
        .testTarget(name: "MIDIEngineTests", dependencies: ["MIDIEngine", "ProjectModel"])
    ]
)
