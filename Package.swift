// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevSweep",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DevSweep", targets: ["DevSweep"]),
        .executable(name: "DevSweepUpdater", targets: ["DevSweepUpdater"])
    ],
    targets: [
        .executableTarget(
            name: "DevSweep",
            path: "Sources/DevSweep"
        ),
        .executableTarget(
            name: "DevSweepUpdater",
            path: "Sources/DevSweepUpdater"
        ),
        .testTarget(
            name: "DevSweepTests",
            dependencies: ["DevSweep", "DevSweepUpdater"]
        )
    ]
)
