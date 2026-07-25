// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SetlistMac",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "SetlistMac", targets: ["SetlistMac"]),
    ],
    targets: [
        .executableTarget(
            name: "SetlistMac"
        ),
        .testTarget(
            name: "SetlistMacTests",
            dependencies: ["SetlistMac"]
        ),
    ]
)
