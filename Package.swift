// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftlyKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SwiftlyKit",
            targets: ["SwiftlyKit"]
        )
    ],
    targets: [
        .target(
            name: "SwiftlyKit"
        ),
        .testTarget(
            name: "SwiftlyKitTests",
            dependencies: ["SwiftlyKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
