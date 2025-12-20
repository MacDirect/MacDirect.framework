// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDirect",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MacDirect",
            targets: ["MacDirect"]
        ),
    ],
    targets: [
        .target(
            name: "MacDirect",
            dependencies: [],
            path: "Sources"
        )
    ]
)
