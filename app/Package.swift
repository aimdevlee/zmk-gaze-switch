// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GazeSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "GazeSwitch", path: "Sources/GazeSwitch")
    ]
)
