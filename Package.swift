// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Schous",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Schous", path: "Sources/Schous")
    ]
)
