// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Triple",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Triple",
            targets: ["Triple"]
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
            name: "Triple",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .testTarget(
            name: "TripleTests",
            dependencies: [
                "Triple",
                "TripleCoordinationFixture"
            ],
            resources: [
                .copy("Fixtures/CrossCompilationPackage"),
                .copy("Fixtures/TraitConditionalPackage")
            ]
        ),
        .executableTarget(
            name: "TripleCoordinationFixture",
            dependencies: ["Triple"],
            path: "Tests/Fixtures/Coordination"
        )
    ],
    swiftLanguageModes: [.v6]
)
