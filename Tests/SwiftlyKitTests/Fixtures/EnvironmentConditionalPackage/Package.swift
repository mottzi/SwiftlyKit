// swift-tools-version: 6.0

import PackageDescription

if let secret = Context.environment["FAILURE_SECRET"] {
    fatalError("Manifest exposed \(secret)")
}

let flavor = Context.environment["PACKAGE_FLAVOR"] ?? "development"
let productName = flavor == "production" ? "ProductionTool" : "DevelopmentTool"

let package = Package(
    name: "EnvironmentConditionalPackage",
    products: [
        .executable(
            name: productName,
            targets: ["Tool"]
        )
    ],
    targets: [
        .executableTarget(name: "Tool")
    ]
)
