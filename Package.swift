// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MajorTom",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "MajorTomCore", targets: ["MajorTomCore"]),
        .executable(name: "MajorTom", targets: ["MajorTom"])
    ],
    targets: [
        .target(name: "MajorTomCore"),
        .executableTarget(
            name: "MajorTom",
            dependencies: ["MajorTomCore"]
        ),
        .testTarget(
            name: "MajorTomCoreTests",
            dependencies: ["MajorTomCore"]
        )
    ]
)
