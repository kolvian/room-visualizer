// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StyleTransferEngine",
    platforms: [
        .iOS(.v15),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "StyleTransferEngine", targets: ["StyleTransferEngine"])
    ],
    targets: [
        .target(name: "StyleTransferEngine", dependencies: []),
        .testTarget(name: "StyleTransferEngineTests", dependencies: ["StyleTransferEngine"])
    ]
)
