// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StowModules",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StowCore", targets: ["StowCore"]),
        .library(name: "StowGitHub", targets: ["StowGitHub"]),
        .library(name: "StowExtensionSDK", targets: ["StowExtensionSDK"]),
        .library(name: "StowExtensions", targets: ["StowExtensions"]),
        .library(name: "StowSampleExtension", targets: ["StowSampleExtension"]),
    ],
    targets: [
        .target(name: "StowExtensionSDK"),
        .target(name: "StowCore", dependencies: ["StowExtensionSDK"]),
        .target(name: "StowGitHub", dependencies: ["StowCore"]),
        .target(name: "StowExtensions", dependencies: ["StowExtensionSDK"]),
        .target(name: "StowSampleExtension", dependencies: ["StowExtensionSDK"]),
        .testTarget(name: "StowCoreTests", dependencies: ["StowCore"]),
        .testTarget(
            name: "StowGitHubTests", dependencies: ["StowGitHub", "StowCore"], resources: [.process("Fixtures")]),
        .testTarget(
            name: "StowExtensionTests", dependencies: ["StowExtensionSDK", "StowExtensions", "StowSampleExtension"]),
    ]
)
