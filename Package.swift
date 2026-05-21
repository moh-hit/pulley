// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pulley",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Pulley",
            path: "Sources/Pulley",
            resources: [.process("Resources")]
        )
    ]
)
