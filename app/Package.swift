// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeChat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeChat", path: "Sources/ClaudeChat")
    ]
)
