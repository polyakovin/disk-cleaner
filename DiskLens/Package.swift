// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiskLens", targets: ["DiskLens"]),
        .executable(name: "disklens-cli", targets: ["DiskLensCLI"])
    ],
    targets: [
        .target(name: "DiskLensCore"),
        .executableTarget(name: "DiskLens", dependencies: ["DiskLensCore"]),
        .executableTarget(name: "DiskLensCLI", dependencies: ["DiskLensCore"]),
        .testTarget(name: "DiskLensCoreTests", dependencies: ["DiskLensCore"])
    ]
)
