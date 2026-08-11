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
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            exact: "1.0.0"
        )
    ],
    targets: [
        .target(
            name: "SwiftlyKit",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .testTarget(
            name: "SwiftlyKitTests",
            dependencies: ["SwiftlyKit"],
            resources: [
                .copy("Fixtures/CrossCompilationPackage")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
