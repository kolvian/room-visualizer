// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ARRoomMapping",
    platforms: [
        .iOS(.v15),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "ARRoomMapping", targets: ["ARRoomMapping"])
    ],
    targets: [
        .target(name: "ARRoomMapping", dependencies: []),
        .testTarget(name: "ARRoomMappingTests", dependencies: ["ARRoomMapping"])
    ]
)
