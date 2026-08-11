// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ScreenTimeRoasterMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RoasterCore", targets: ["RoasterCore"]),
        .executable(name: "RoasterMac", targets: ["RoasterMac"]),
        .executable(name: "RoasterEnforcer", targets: ["RoasterEnforcer"]),
        .executable(name: "RoasterBlocklist", targets: ["RoasterBlocklist"]),
        .executable(name: "RoasterInstaller", targets: ["RoasterInstaller"]),
    ],
    targets: [
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
        .testTarget(
            name: "RoasterCoreTests",
            dependencies: ["RoasterCore"]
        ),
    ]
)
