// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CC360Framer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CC360Framer", path: "Sources/CC360Framer", exclude: ["Assets"]),
        .testTarget(name: "CC360FramerTests", dependencies: ["CC360Framer"], path: "Tests/CC360FramerTests")
    ]
)
