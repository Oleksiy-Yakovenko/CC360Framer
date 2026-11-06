// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CC360Framer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CC360Framer", path: "Sources/CC360Framer", exclude: ["Assets"],
                          // SwiftPM (also inside Xcode) records the deployment target (14.0) as the binary's SDK version, and macOS
                          // only gives the new Liquid Glass look to binaries linked against SDK 26 or later. Keep minos 14.0 but record
                          // SDK 26.2 (the value of a known good Xcode-built app); it only has to be >= 26.
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
                                                         "-Xlinker", "14.0", "-Xlinker", "26.2"])]),
        .testTarget(name: "CC360FramerTests", dependencies: ["CC360Framer"], path: "Tests/CC360FramerTests")
    ]
)
