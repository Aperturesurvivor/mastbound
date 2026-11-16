// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Mastbound",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MastboundCore", targets: ["MastboundCore"]),
        .executable(name: "mastboundd", targets: ["mastboundd"]),
        .executable(name: "mastboundctl", targets: ["mastboundctl"]),
    ],
    targets: [
        .target(name: "MastboundCore"),
        .executableTarget(name: "mastboundd", dependencies: ["MastboundCore"]),
        .executableTarget(name: "mastboundctl", dependencies: ["MastboundCore"]),
        .executableTarget(name: "make-list", dependencies: ["MastboundCore"]),
        // Draft UI for Josiah's review (P6). Not shipped.
        .executableTarget(name: "MastboundApp", dependencies: ["MastboundCore"]),
        .testTarget(name: "MastboundCoreTests", dependencies: ["MastboundCore"]),
        .testTarget(name: "MastboundIntegrationTests", dependencies: ["MastboundCore"]),
    ]
)
