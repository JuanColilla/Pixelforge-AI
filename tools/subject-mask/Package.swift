// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "subject-mask",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "subject-mask")
    ]
)
