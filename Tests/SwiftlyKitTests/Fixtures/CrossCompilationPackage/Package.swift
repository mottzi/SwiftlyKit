// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CrossCompilationFixture",
    products: [
        .executable(name: "CrossCompilationFixture", targets: ["CrossCompilationFixture"])
    ],
    targets: [
        .executableTarget(name: "CrossCompilationFixture")
    ]
)
