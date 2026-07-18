// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PagePassCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PagePassCore", targets: ["PagePassCore"])
    ],
    targets: [
        .target(name: "PagePassCore"),
        .testTarget(
            name: "PagePassCoreTests",
            dependencies: ["PagePassCore"]
        )
    ]
)

