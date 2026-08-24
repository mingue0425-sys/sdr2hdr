// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HDRCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HDRCore", targets: ["HDRCore"]),
        .executable(name: "HDRBenchmark", targets: ["HDRBenchmark"]),
        .executable(name: "HDRSample", targets: ["HDRSample"]),
        .executable(name: "HDRPlayer", targets: ["HDRPlayer"]),
        .executable(name: "HDRCalibrate", targets: ["HDRCalibrate"])
    ],
    targets: [
        .target(
            name: "HDRCore",
            resources: [
                .process("Shaders")
            ]
        ),
        .executableTarget(
            name: "HDRBenchmark",
            dependencies: ["HDRCore", "HDRPlayerKit"]
        ),
        .executableTarget(
            name: "HDRSample",
            dependencies: ["HDRCore"]
        ),
        .target(
            name: "HDRPlayerKit",
            dependencies: ["HDRCore"],
            path: "Sources/HDRPlayer",
            resources: [
                .process("Shaders")
            ]
        ),
        .executableTarget(
            name: "HDRPlayer",
            dependencies: ["HDRPlayerKit"],
            path: "Sources/HDRPlayerCLI"
        ),
        .target(
            name: "HDRCalibration",
            dependencies: ["HDRCore"],
            path: "Sources/HDRCalibration"
        ),
        .executableTarget(
            name: "HDRCalibrate",
            dependencies: ["HDRCalibration"],
            path: "Sources/HDRCalibrate"
        ),
        .testTarget(
            name: "HDRCoreTests",
            dependencies: ["HDRCore"]
        ),
        .testTarget(
            name: "HDRPlayerTests",
            dependencies: ["HDRPlayerKit"]
        ),
        .testTarget(
            name: "HDRCalibrationTests",
            dependencies: ["HDRCalibration", "HDRCore"]
        )
    ]
)
