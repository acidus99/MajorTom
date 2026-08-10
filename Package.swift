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
        .target(name: "MajorTomAppKitSupport"),
        .executableTarget(
            name: "MajorTom",
            dependencies: ["MajorTomCore", "MajorTomAppKitSupport"],
            resources: [
                .copy("Resources/major-tom.mid")
            ]
        ),
        .testTarget(
            name: "MajorTomCoreTests",
            dependencies: ["MajorTomCore"]
        ),
        .testTarget(
            name: "MajorTomAppKitTests",
            dependencies: ["MajorTomAppKitSupport"]
        )
    ]
)
