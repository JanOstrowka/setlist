// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SetlistMac",
    platforms: [
        .macOS(.v13),
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
