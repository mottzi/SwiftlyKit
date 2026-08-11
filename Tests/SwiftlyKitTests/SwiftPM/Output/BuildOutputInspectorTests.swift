import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Build output inspector")
struct BuildOutputInspectorTests {

    @Test("Ignores Apple privacy metadata bundles")
    func privacyMetadata() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            let resources = try createResourceBundle(named: "Dependency_Metadata.resources", in: directory)
            try Data("privacy metadata".utf8).write(to: resources.appending(path: "PrivacyInfo.xcprivacy"))

            #expect(try BuildOutputInspector.runtimeResourceBundles(in: directory).isEmpty)
        }
    }

    @Test("Returns runtime resource bundles in stable name order")
    func runtimeResources() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            let second = try createResourceBundle(named: "Second_Assets.resources", in: directory)
            let first = try createResourceBundle(named: "First_Assets.resources", in: directory)
            try Data("asset".utf8).write(to: first.appending(path: "asset.txt"))
            try Data("asset".utf8).write(to: second.appending(path: "asset.txt"))

            #expect(try BuildOutputInspector.runtimeResourceBundles(in: directory) == [
                "First_Assets.resources",
                "Second_Assets.resources"
            ])
        }
    }

    @Test("Treats mixed, nested, empty, and symbolic-link bundles as runtime resources")
    func conservativeClassification() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-BuildOutput") { directory in
            let mixed = try createResourceBundle(named: "Mixed.resources", in: directory)
            try Data().write(to: mixed.appending(path: "PrivacyInfo.xcprivacy"))
            try Data().write(to: mixed.appending(path: "asset.txt"))

            let nested = try createResourceBundle(named: "Nested.resources", in: directory)
            try FileManager.default.createDirectory(
                at: nested.appending(path: "Assets"),
                withIntermediateDirectories: false
            )

            _ = try createResourceBundle(named: "Empty.resources", in: directory)

            let target = try createResourceBundle(named: "Target", in: directory)
            try FileManager.default.createSymbolicLink(
                at: directory.appending(path: "Linked.resources"),
                withDestinationURL: target
            )

            #expect(try BuildOutputInspector.runtimeResourceBundles(in: directory) == [
                "Empty.resources",
                "Linked.resources",
                "Mixed.resources",
                "Nested.resources"
            ])
        }
    }

    private func createResourceBundle(named name: String, in directory: URL) throws -> URL {

        let resources = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        return resources
    }

}
