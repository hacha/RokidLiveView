// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RokidLiveView",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RokidLiveView", path: "Sources/RokidLiveView")
    ]
)
