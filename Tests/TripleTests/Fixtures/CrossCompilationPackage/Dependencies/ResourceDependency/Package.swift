// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ResourceDependency",
    products: [
        .library(name: "ResourceDependency", targets: ["ResourceDependency"])
    ],
    targets: [
        .target(
            name: "ResourceDependency",
            resources: [.copy("message.txt")]
        )
    ]
)
