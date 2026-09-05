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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "MajorTomCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(name: "MajorTomAppKitSupport"),
        .executableTarget(
            name: "MajorTom",
            dependencies: ["MajorTomCore", "MajorTomAppKitSupport"]
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
