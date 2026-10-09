import Foundation
import Testing
@testable import Triple

@Suite("Swift Build output inspection")
struct SwiftBuildOutputTests {

    @Test("Only the selected executable's active linked resources are exported", arguments: [BuildConfiguration.debug, .release])
    func linkedResources(configuration: BuildConfiguration) throws {
        try withTemporaryDirectory(prefix: "Triple-SwiftBuildOutput") { scratch in
            let directory = try productsDirectory(in: scratch)
            for name in ["Root", "Dependency", "Host", "OtherProduct", "GNU", "Stale"] {
                try makeBundle(name, in: directory)
            }
            let targets = [
                pifTarget("tool", product: "Tool", bundle: "Root", links: [
                    link("library"), link("gnu", platform: "linux", environment: "gnu")
                ], dependencies: ["host"]),
                pifTarget("library", type: "packageProduct", links: [link("dependency", platform: "linux", environment: "musl")]),
                pifTarget("dependency", bundle: "Dependency", links: [link("host", platform: "macos")]),
                pifTarget("host", bundle: "Host"),
                pifTarget("gnu", bundle: "GNU"),
                pifTarget("other", product: "Other", bundle: "OtherProduct")
            ]
            try writePIF(targets, in: scratch)

            let output = try SwiftPMBuildOutput.inspect(
                product: "Tool", in: directory, scratchDirectory: scratch, configuration: configuration
            )
            #expect(output.resourceBundles.map(\.lastPathComponent) == ["Dependency.bundle", "Root.bundle"])
            #expect(output.executable == directory.appending(path: "Tool"))
        }
    }

    @Test("A product without resources ignores unrelated bundles")
    func resourceFreeProduct() throws {
        try withTemporaryDirectory(prefix: "Triple-SwiftBuildOutput") { scratch in
            let directory = try productsDirectory(in: scratch)
            try makeBundle("Stale", in: directory)
            try writePIF([pifTarget("tool", product: "Tool")], in: scratch)

            let output = try SwiftPMBuildOutput.inspect(
                product: "Tool", in: directory, scratchDirectory: scratch, configuration: .release
            )
            #expect(output.resourceBundles.isEmpty)
        }
    }

    @Test("Missing linked bundles fail even when the output directory has no bundles")
    func missingBundle() throws {
        try withTemporaryDirectory(prefix: "Triple-SwiftBuildOutput") { scratch in
            let directory = try productsDirectory(in: scratch)
            try writePIF([pifTarget("tool", product: "Tool", bundle: "Missing")], in: scratch)
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(
                    product: "Tool", in: directory, scratchDirectory: scratch, configuration: .release
                )
            }
        }
    }

    @Test("The selected configuration determines the resource name")
    func configurationSelection() throws {
        try withTemporaryDirectory(prefix: "Triple-SwiftBuildOutput") { scratch in
            let directory = try productsDirectory(in: scratch)
            try makeBundle("DebugResources", in: directory)
            try makeBundle("ReleaseResources", in: directory)
            var target = pifTarget("tool", product: "Tool")
            target["buildConfigurations"] = ["Debug", "Release"].map { name in
                ["name": name, "buildSettings": [
                    "TARGET_NAME": "Tool", "PACKAGE_RESOURCE_BUNDLE_NAME": name + "Resources"
                ]] as [String: Any]
            }
            try writePIF([target], in: scratch)
            let output = try SwiftPMBuildOutput.inspect(
                product: "Tool", in: directory, scratchDirectory: scratch, configuration: .debug
            )
            #expect(output.resourceBundles.map(\.lastPathComponent) == ["DebugResources.bundle"])
        }
    }

    @Test("Malformed and ambiguous project models fail closed", arguments: ["missing", "invalid", "duplicate", "unknownLink", "unsafeName", "duplicateBundle", "symlink"])
    func invalidMetadata(kind: String) throws {
        try withTemporaryDirectory(prefix: "Triple-SwiftBuildOutput") { scratch in
            let directory = try productsDirectory(in: scratch)
            var targets = [pifTarget("tool", product: "Tool", bundle: "Root")]
            switch kind {
                case "duplicate": targets.append(pifTarget("second", product: "Tool"))
                case "unknownLink": targets = [pifTarget("tool", product: "Tool", links: [link("missing")])]
                case "unsafeName": targets = [pifTarget("tool", product: "Tool", bundle: "../outside")]
                case "duplicateBundle": targets = [
                    pifTarget("tool", product: "Tool", bundle: "Root", links: [link("library")]),
                    pifTarget("library", bundle: "Root")
                ]
                default: break
            }
            if kind != "missing" { try writePIF(targets, in: scratch) }
            let manifest = scratch.appending(path: "manifest.pif")
            if kind == "invalid" { try Data("{}".utf8).write(to: manifest) }
            if kind == "symlink" {
                let original = scratch.appending(path: "original.pif")
                try FileManager.default.moveItem(at: manifest, to: original)
                try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: original)
            }
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(
                    product: "Tool", in: directory, scratchDirectory: scratch, configuration: .release
                )
            }
        }
    }

    @Test("Generated Info.plist does not turn a privacy-only bundle into runtime resources", arguments: [false, true])
    func privacyBundle(hasRuntimeResources: Bool) throws {
        try withTemporaryDirectory(prefix: "Triple-SwiftBuildOutput") { scratch in
            let directory = try productsDirectory(in: scratch)
            try makeBundle("Metadata", in: directory)
            let bundle = directory.appending(path: "Metadata.bundle", directoryHint: .isDirectory)
            try Data("privacy".utf8).write(to: bundle.appending(path: "PrivacyInfo.xcprivacy"))
            try Data("metadata".utf8).write(to: bundle.appending(path: "Info.plist"))
            if hasRuntimeResources { try Data("asset".utf8).write(to: bundle.appending(path: "asset.txt")) }
            try writePIF([pifTarget("tool", product: "Tool", bundle: "Metadata")], in: scratch)
            let output = try SwiftPMBuildOutput.inspect(
                product: "Tool", in: directory, scratchDirectory: scratch, configuration: .release
            )
            #expect(output.resourceBundles == (hasRuntimeResources ? [bundle] : []))
        }
    }

}

private func productsDirectory(in scratch: URL) throws -> URL {
    let directory = scratch.appending(path: "out/Products/Release-staticlinux-x86_64", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeBundle(_ name: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory.appending(path: name + ".bundle"), withIntermediateDirectories: false)
}

private func writePIF(_ targets: [[String: Any]], in scratch: URL) throws {
    let objects = targets.map { ["type": "target", "contents": $0] as [String: Any] }
    try JSONSerialization.data(withJSONObject: objects).write(to: scratch.appending(path: "manifest.pif"))
}

private func link(_ guid: String, platform: String? = nil, environment: String? = nil) -> [String: Any] {
    var filters: [[String: String]] = []
    if let platform {
        var filter = ["platform": platform]
        if let environment { filter["environment"] = environment }
        filters = [filter]
    }
    return ["targetReference": guid, "platformFilters": filters]
}

private func pifTarget(
    _ guid: String,
    type: String = "standard",
    product: String? = nil,
    bundle: String? = nil,
    links: [[String: Any]] = [],
    dependencies: [String] = []
) -> [String: Any] {
    var settings: [String: String] = [:]
    if let product { settings["TARGET_NAME"] = product }
    if let bundle { settings["PACKAGE_RESOURCE_BUNDLE_NAME"] = bundle }
    var target: [String: Any] = [
        "guid": guid, "type": type,
        "buildConfigurations": ["Debug", "Release"].map { ["name": $0, "buildSettings": settings] as [String: Any] },
        "dependencies": dependencies.map { ["guid": $0, "platformFilters": []] as [String: Any] }
    ]
    if product != nil { target["productTypeIdentifier"] = "com.apple.product-type.tool" }
    let phase: [String: Any] = ["type": "com.apple.buildphase.frameworks", "buildFiles": links]
    if type == "packageProduct" { target["frameworksBuildPhase"] = phase }
    else { target["buildPhases"] = [phase] }
    return target
}
