// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "mergehawk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "mergehawkcore", targets: ["mergehawkcore"]),
        .executable(name: "mergehawk", targets: ["mergehawk"]),
        .executable(name: "mergehawkcoretestrunner", targets: ["mergehawkcoretestrunner"])
    ],
    targets: [
        .target(name: "mergehawkcore"),
        .executableTarget(
            name: "mergehawk",
            dependencies: ["mergehawkcore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "mergehawkcoretestrunner",
            dependencies: ["mergehawkcore"]
        ),
        .testTarget(
            name: "SmokeTests",
            dependencies: ["mergehawkcore"],
            path: "Tests/SmokeTests"
        ),
        .testTarget(
            name: "mergehawktests",
            dependencies: ["mergehawk", "mergehawkcore"],
            path: "Tests/mergehawktests"
        )
    ]
)
