// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTranscribe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacTranscribe", path: "Sources/MacTranscribe")
    ]
)
