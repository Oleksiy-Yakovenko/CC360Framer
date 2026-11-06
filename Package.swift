// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CC360Framer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CC360Framer", path: "Sources/CC360Framer"),
        .testTarget(name: "CC360FramerTests", dependencies: ["CC360Framer"], path: "Tests/CC360FramerTests")
    ]
)
