// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CrossCompilationFixture",
    products: [
        .executable(name: "CrossCompilationFixture", targets: ["CrossCompilationFixture"])
    ],
    dependencies: [
        .package(path: "Dependencies/ResourceDependency")
    ],
    targets: [
        .executableTarget(
            name: "CrossCompilationFixture",
            dependencies: [
                .product(name: "ResourceDependency", package: "ResourceDependency")
            ]
        )
    ]
)
