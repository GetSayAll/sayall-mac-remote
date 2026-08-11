// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SayAllMacRemote",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SayAllMacRemoteCore",
            targets: ["SayAllMacRemoteCore"]
        ),
        .library(
            name: "SayAllMacRemoteUI",
            targets: ["SayAllMacRemoteUI"]
        ),
    ],
    targets: [
        .target(name: "SayAllMacRemoteCore"),
        .target(
            name: "SayAllMacRemoteUI",
            dependencies: ["SayAllMacRemoteCore"]
        ),
        .testTarget(
            name: "SayAllMacRemoteCoreTests",
            dependencies: ["SayAllMacRemoteCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
