// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ScreenTimeRoaster",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MastboundCore", targets: ["MastboundCore"]),
        .executable(name: "mastboundd", targets: ["mastboundd"]),
        .executable(name: "mastboundctl", targets: ["mastboundctl"]),
        .library(name: "RoasterCore", targets: ["RoasterCore"]),
        .executable(name: "RoasterMac", targets: ["RoasterMac"]),
        .executable(name: "RoasterEnforcer", targets: ["RoasterEnforcer"]),
        .executable(name: "RoasterBlocklist", targets: ["RoasterBlocklist"]),
        .executable(name: "RoasterInstaller", targets: ["RoasterInstaller"]),
        .executable(name: "RoasterToolFetch", targets: ["RoasterToolFetch"]),
    ],
    targets: [
        // Rewrite targets (see docs/rewrite-plan.md).
        .target(name: "MastboundCore"),
        .executableTarget(name: "mastboundd", dependencies: ["MastboundCore"]),
        .executableTarget(name: "mastboundctl", dependencies: ["MastboundCore"]),
        .testTarget(name: "MastboundCoreTests", dependencies: ["MastboundCore"]),

        // Legacy targets. Removed in phase P4.
        .target(name: "RoasterCore"),
        .executableTarget(
            name: "RoasterMac",
            dependencies: ["RoasterCore"]
        ),
        .executableTarget(
            name: "RoasterEnforcer",
            dependencies: ["RoasterCore"]
        ),
        .executableTarget(
            name: "RoasterBlocklist",
            dependencies: ["RoasterCore"]
        ),
        .executableTarget(
            name: "RoasterInstaller",
            dependencies: ["RoasterCore"]
        ),
        .executableTarget(
            name: "RoasterToolFetch",
            dependencies: ["RoasterCore"]
        ),
        .testTarget(
            name: "RoasterCoreTests",
            dependencies: ["RoasterCore"]
        ),
    ]
)
