import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftPM build output inspection")
struct SwiftPMBuildOutputTests {

    @Test("An output without resource candidates needs no private SwiftPM metadata")
    func noResources() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            try createLinkMetadata(
                product: "Tool",
                modules: [("Missing", "Package_Missing.resources")],
                in: directory
            )

            let output = try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)

            #expect(output.executable == directory.appending(path: "Tool"))
            #expect(output.resourceBundles.isEmpty)
        }
    }

    @Test("Linked root and dependency bundles are returned in stable name order")
    func linkedResources() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            let second = try createBundle(named: "Package_Second.resources", in: directory)
            let first = try createBundle(named: "Package_First.resources", in: directory)
            _ = try createBundle(named: "Unrelated_Stale.resources", in: directory)
            try createLinkMetadata(
                product: "Tool",
                modules: [
                    ("Second", second.lastPathComponent),
                    ("First", first.lastPathComponent)
                ],
                in: directory
            )

            let output = try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            #expect(output.resourceBundles.map(\.lastPathComponent) == [
                "Package_First.resources",
                "Package_Second.resources"
            ])
        }
    }

    @Test("A resource-free product ignores unrelated stale resource bundles")
    func resourceFreeProductIgnoresStaleBundles() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            _ = try createBundle(named: "Unrelated_Stale.resources", in: directory)
            let productDirectory = directory.appending(path: "Tool.product", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: productDirectory, withIntermediateDirectories: false)
            let linkFile = productDirectory.appending(path: "Objects.LinkFileList")
            try Data("/external/Tool.build/main.swift.o\n".utf8).write(to: linkFile)

            let output = try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)

            #expect(output.resourceBundles.isEmpty)
        }
    }

    @Test("An empty selected-product link file fails closed when resource candidates exist")
    func emptyLinkFile() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            _ = try createBundle(named: "Unrelated_Stale.resources", in: directory)
            let productDirectory = directory.appending(path: "Tool.product", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: productDirectory, withIntermediateDirectories: false)
            try Data().write(to: productDirectory.appending(path: "Objects.LinkFileList"))

            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }
        }
    }

    @Test("A linked privacy-only bundle remains part of the runnable output")
    func privacyResources() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            let bundle = try createBundle(named: "Package_Metadata.resources", in: directory)
            try Data("privacy".utf8).write(to: bundle.appending(path: "PrivacyInfo.xcprivacy"))
            try createLinkMetadata(
                product: "Tool",
                modules: [("Metadata", bundle.lastPathComponent)],
                in: directory
            )

            let output = try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            #expect(output.resourceBundles == [bundle])
        }
    }

    @Test("Resource candidates without linked accessor metadata fail closed")
    func missingLinkMetadata() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            _ = try createBundle(named: "Package_Assets.resources", in: directory)

            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }
        }
    }

    @Test("A linked bundle that is absent fails closed")
    func missingLinkedBundle() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            _ = try createBundle(named: "Unrelated_Stale.resources", in: directory)
            try createLinkMetadata(
                product: "Tool",
                modules: [("Assets", "Package_Assets.resources")],
                in: directory
            )

            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }
        }
    }

    @Test("Malformed, escaping, and symbolic-link metadata fail closed")
    func unsafeMetadata() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            let bundle = try createBundle(named: "Package_Assets.resources", in: directory)
            let otherBundle = try createBundle(named: "Package_Other.resources", in: directory)
            try createLinkMetadata(
                product: "Tool",
                modules: [("Assets", bundle.lastPathComponent)],
                in: directory
            )

            let accessor = directory
                .appending(path: "Assets.build/DerivedSources/resource_bundle_accessor.swift")
            let ambiguousSource = """
            let first = "Package_Assets.resources"
            let firstBuild = "\(bundle.path(percentEncoded: false))"
            let second = "Package_Other.resources"
            let secondBuild = "\(otherBundle.path(percentEncoded: false))"
            """
            try Data(ambiguousSource.utf8).write(to: accessor)
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }

            try Data([0xff]).write(to: accessor)
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }

            try Data(#"let path = "/tmp/Package_Assets.resources""#.utf8).write(to: accessor)
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }

            try FileManager.default.removeItem(at: accessor)
            let outside = directory.deletingLastPathComponent().appending(path: UUID().uuidString)
            try Data(#"let path = "Package_Assets.resources""#.utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(at: accessor, withDestinationURL: outside)
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }
        }
    }

    @Test("Malformed, escaping, and symbolic-link link files fail closed")
    func unsafeLinkFile() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            _ = try createBundle(named: "Package_Assets.resources", in: directory)
            let productDirectory = directory.appending(path: "Tool.product", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: productDirectory, withIntermediateDirectories: false)
            let linkFile = productDirectory.appending(path: "Objects.LinkFileList")

            try Data([0xff]).write(to: linkFile)
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }

            let escapingObject = directory
                .deletingLastPathComponent()
                .appending(path: "Outside.build/resource_bundle_accessor.swift.o")
            try Data(escapingObject.path(percentEncoded: false).utf8).write(to: linkFile)
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }

            try FileManager.default.removeItem(at: linkFile)
            let outside = directory.deletingLastPathComponent().appending(path: UUID().uuidString)
            try Data().write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(at: linkFile, withDestinationURL: outside)
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }
        }
    }

    @Test("Symbolic links and hard links in a linked resource tree fail closed")
    func unsafeResourceTree() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            let bundle = try createBundle(named: "Package_Assets.resources", in: directory)
            let file = bundle.appending(path: "asset.txt")
            try Data("asset".utf8).write(to: file)
            try createLinkMetadata(
                product: "Tool",
                modules: [("Assets", bundle.lastPathComponent)],
                in: directory
            )

            try FileManager.default.createSymbolicLink(
                at: bundle.appending(path: "linked.txt"),
                withDestinationURL: file
            )
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }

            try FileManager.default.removeItem(at: bundle.appending(path: "linked.txt"))
            try FileManager.default.linkItem(at: file, to: bundle.appending(path: "hard-linked.txt"))
            #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try SwiftPMBuildOutput.inspect(product: "Tool", in: directory)
            }
        }
    }

}

private func createBundle(named name: String, in directory: URL) throws -> URL {

    let bundle = directory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    return bundle
}

private func createLinkMetadata(product: String, modules: [(String, String)], in directory: URL) throws {

    let productDirectory = directory.appending(path: "\(product).product", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: productDirectory, withIntermediateDirectories: false)
    var objects: [String] = []

    for (module, bundle) in modules {
        let buildDirectory = directory.appending(path: "\(module).build", directoryHint: .isDirectory)
        let derivedSources = buildDirectory.appending(path: "DerivedSources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: derivedSources, withIntermediateDirectories: true)
        let object = buildDirectory.appending(path: "resource_bundle_accessor.swift.o")
        try Data().write(to: object)
        objects.append(object.path(percentEncoded: false))

        let accessor = derivedSources.appending(path: "resource_bundle_accessor.swift")
        let source = """
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("\(bundle)").path
        let buildPath = "\(directory.appending(path: bundle).path(percentEncoded: false))"
        """
        try Data(source.utf8).write(to: accessor)
    }

    let linkFile = productDirectory.appending(path: "Objects.LinkFileList")
    try Data(objects.joined(separator: "\n").utf8).write(to: linkFile)
}
