// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Schous",
    // 14.2, ikke 14.0: Core Audio process taps (Recorder.swift) kom først der.
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "Schous", path: "Sources/Schous")
    ]
)
