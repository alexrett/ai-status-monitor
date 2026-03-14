// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIStatusMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "AIStatusMonitor")
    ]
)
