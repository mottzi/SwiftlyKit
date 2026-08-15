// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "TraitConditionalPackage",
    products: [
        .executable(name: "Tool", targets: ["Tool"])
    ],
    traits: [
        .trait(name: "DefaultFeature"),
        .trait(name: "SelectedFeature"),
        .default(enabledTraits: ["DefaultFeature"])
    ],
    targets: [
        .executableTarget(
            name: "Tool",
            swiftSettings: [
                .define("DEFAULT_FEATURE", .when(traits: ["DefaultFeature"])),
                .define("SELECTED_FEATURE", .when(traits: ["SelectedFeature"]))
            ]
        )
    ]
)
