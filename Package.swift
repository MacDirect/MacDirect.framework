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
            name: "MacDirectSecurity",
            dependencies: [],
            path: "Sources/MacDirectSecurity"
        ),
        .target(
            name: "MacDirect",
            dependencies: ["MacDirectSecurity"],
            path: "Sources",
            exclude: ["UpdateHelper", "MacDirectSecurity"],
            resources: [
                .copy("Resources/MacDirectUpdater.app")
            ]
        ),
        .executableTarget(
            name: "MacDirectUpdater",
            dependencies: ["MacDirectSecurity"],
            path: "Sources/UpdateHelper"
        )
    ]
)
