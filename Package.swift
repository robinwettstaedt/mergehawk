// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "vc-dash",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VCDashCore", targets: ["VCDashCore"]),
        .executable(name: "VCDash", targets: ["VCDash"]),
        .executable(name: "VCDashCoreTestRunner", targets: ["VCDashCoreTestRunner"])
    ],
    targets: [
        .target(name: "VCDashCore"),
        .executableTarget(
            name: "VCDash",
            dependencies: ["VCDashCore"]
        ),
        .executableTarget(
            name: "VCDashCoreTestRunner",
            dependencies: ["VCDashCore"]
        ),
        .testTarget(
            name: "SmokeTests",
            dependencies: ["VCDashCore"],
            path: "Tests/SmokeTests"
        )
    ]
)
