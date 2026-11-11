// swift-tools-version: 6.4

import PackageDescription

let memberImportVisibility: [SwiftSetting] = [.enableUpcomingFeature("MemberImportVisibility")]

let package = Package(
    name: "simdrive",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "simdrive", targets: ["simdrive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lynnswap/ABIBridge.git", exact: "0.19.1"),
    ],
    targets: [
        // Private-framework glue: CoreSimulator, guest HID services, CoreDevice.
        .target(name: "SimDriveNative", dependencies: [
            .product(name: "ABIBridge", package: "ABIBridge"),
        ], swiftSettings: memberImportVisibility),
        // Device sessions, commands, screen geometry, and the per-simulator daemon.
        .target(name: "SimDriveCore", dependencies: ["SimDriveNative"], swiftSettings: memberImportVisibility),
        .executableTarget(name: "simdrive", dependencies: ["SimDriveCore"], swiftSettings: memberImportVisibility),
        .testTarget(name: "SimDriveCoreTests", dependencies: ["SimDriveCore", "SimDriveNative"], swiftSettings: memberImportVisibility),
    ]
)
