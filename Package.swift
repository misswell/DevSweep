// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevSweep",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DevSweep", targets: ["DevSweep"])
    ],
    targets: [
        .executableTarget(
            name: "DevSweep",
            path: "Sources/DevSweep"
        )
    ]
)
