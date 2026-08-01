// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MajorTomNative",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "MajorTomCore", targets: ["MajorTomCore"]),
        .executable(name: "MajorTomNative", targets: ["MajorTomNative"])
    ],
    targets: [
        .target(name: "MajorTomCore"),
        .executableTarget(
            name: "MajorTomNative",
            dependencies: ["MajorTomCore"]
        ),
        .testTarget(
            name: "MajorTomCoreTests",
            dependencies: ["MajorTomCore"]
        )
    ]
)
