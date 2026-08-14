import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SDK selection directory")
struct SDKSelectionDirectoryTests {

    @Test("Preparation is deterministic and exposes only the exact SDK")
    func deterministicExactSelection() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKSearchPath") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let bundle = try createBundle(identifier: identifier, in: directory)

            let firstSelection = try SDKSelectionDirectory.resolve(
                sdkIdentifier: identifier,
                sdkBundleURL: bundle,
                scratchDirectory: scratch
            )
            let secondSelection = try SDKSelectionDirectory.resolve(
                sdkIdentifier: identifier,
                sdkBundleURL: bundle,
                scratchDirectory: scratch
            )
            let entries = try FileManager.default.contentsOfDirectory(
                at: firstSelection,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            )
            let link = try #require(entries.first)

            #expect(firstSelection == secondSelection)
            #expect(firstSelection.pathComponents.starts(with: scratch.pathComponents + [
                ".swiftlykit", "sdk-selections"
            ]))
            #expect(entries.count == 1)
            #expect(link.lastPathComponent == bundle.lastPathComponent)
            #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
            #expect(
                link.resolvingSymlinksInPath().pathComponents
                    == bundle.resolvingSymlinksInPath().pathComponents
            )
        }
    }

    @Test("Different SDK bundles use independent exact selections")
    func multipleSDKs() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKSearchPath") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let firstIdentifier = "swift-6.3.2-RELEASE_static-linux-0.1.0"
            let secondIdentifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let firstBundle = try createBundle(identifier: firstIdentifier, in: directory)
            let secondBundle = try createBundle(identifier: secondIdentifier, in: directory)

            let firstSelection = try SDKSelectionDirectory.resolve(
                sdkIdentifier: firstIdentifier,
                sdkBundleURL: firstBundle,
                scratchDirectory: scratch
            )
            let secondSelection = try SDKSelectionDirectory.resolve(
                sdkIdentifier: secondIdentifier,
                sdkBundleURL: secondBundle,
                scratchDirectory: scratch
            )

            #expect(firstSelection != secondSelection)
            #expect(try FileManager.default.contentsOfDirectory(atPath: firstSelection.path(percentEncoded: false)) == [
                firstBundle.lastPathComponent
            ])
            #expect(try FileManager.default.contentsOfDirectory(atPath: secondSelection.path(percentEncoded: false)) == [
                secondBundle.lastPathComponent
            ])
        }
    }

    @Test("A relocated SDK uses a different immutable selection")
    func relocatedSDK() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKSearchPath") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let firstRoot = directory.appending(path: "first", directoryHint: .isDirectory)
            let secondRoot = directory.appending(path: "second", directoryHint: .isDirectory)
            let firstBundle = try createBundle(identifier: identifier, in: firstRoot)
            let secondBundle = try createBundle(identifier: identifier, in: secondRoot)

            let firstSelection = try SDKSelectionDirectory.resolve(
                sdkIdentifier: identifier,
                sdkBundleURL: firstBundle,
                scratchDirectory: scratch
            )
            let secondSelection = try SDKSelectionDirectory.resolve(
                sdkIdentifier: identifier,
                sdkBundleURL: secondBundle,
                scratchDirectory: scratch
            )

            #expect(firstSelection != secondSelection)
        }
    }

    @Test("Concurrent preparation converges on one exact selection")
    func concurrentPreparation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SDKSearchPath") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let bundle = try createBundle(identifier: identifier, in: directory)

            let selections = try await withThrowingTaskGroup(of: URL.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        try SDKSelectionDirectory.resolve(
                            sdkIdentifier: identifier,
                            sdkBundleURL: bundle,
                            scratchDirectory: scratch
                        )
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }

            #expect(Set(selections).count == 1)
            let selection = try #require(selections.first)
            #expect(try FileManager.default.contentsOfDirectory(atPath: selection.path(percentEncoded: false)) == [
                bundle.lastPathComponent
            ])
        }
    }

    @Test("A lost creation race verifies and reuses the winner")
    func lostCreationRace() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKSearchPath") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let bundle = try createBundle(identifier: identifier, in: directory)

            let selection = try SDKSelectionDirectory.resolve(
                sdkIdentifier: identifier,
                sdkBundleURL: bundle,
                scratchDirectory: scratch,
                fileManager: LosingSelectionRaceFileManager()
            )

            let entries = try FileManager.default.contentsOfDirectory(
                at: selection,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            )
            let link = try #require(entries.first)

            #expect(entries.count == 1)
            #expect(
                link.resolvingSymlinksInPath().pathComponents
                    == bundle.resolvingSymlinksInPath().pathComponents
            )
        }
    }

    @Test("Unexpected selection contents are preserved and rejected")
    func unexpectedSelectionContents() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKSearchPath") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let bundle = try createBundle(identifier: identifier, in: directory)
            let selection = try SDKSelectionDirectory.resolve(
                sdkIdentifier: identifier,
                sdkBundleURL: bundle,
                scratchDirectory: scratch
            )
            let unexpectedEntry = selection.appending(path: "unexpected")
            try Data().write(to: unexpectedEntry)

            #expect(throws: SDKSelectionDirectory.Error.self) {
                try SDKSelectionDirectory.resolve(
                    sdkIdentifier: identifier,
                    sdkBundleURL: bundle,
                    scratchDirectory: scratch
                )
            }
            #expect(FileManager.default.fileExists(atPath: unexpectedEntry.path(percentEncoded: false)))
        }
    }

    @Test("A scratch-internal symlink cannot redirect managed selection state")
    func rejectsRedirectedSelectionRoot() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKSearchPath") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let redirectedRoot = directory.appending(path: "redirected", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: redirectedRoot, withIntermediateDirectories: false)
            let redirectedComponent = scratch.appending(path: ".swiftlykit")
            try FileManager.default.createSymbolicLink(
                at: redirectedComponent,
                withDestinationURL: redirectedRoot
            )
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let bundle = try createBundle(identifier: identifier, in: directory)

            let managedComponent = scratch.appending(path: ".swiftlykit", directoryHint: .isDirectory)
            #expect(throws: SDKSelectionDirectory.Error.unexpectedItem(managedComponent.path(percentEncoded: false))) {
                try SDKSelectionDirectory.resolve(
                    sdkIdentifier: identifier,
                    sdkBundleURL: bundle,
                    scratchDirectory: scratch
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: redirectedRoot.path(percentEncoded: false)).isEmpty)
        }
    }

    @Test("Invalid identifiers cannot escape scratch storage")
    func rejectsInvalidIdentifier() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKSearchPath") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let bundle = try createBundle(identifier: "sdk", in: directory)

            #expect(throws: SDKSelectionDirectory.Error.invalidIdentifier("../outside")) {
                try SDKSelectionDirectory.resolve(
                    sdkIdentifier: "../outside",
                    sdkBundleURL: bundle,
                    scratchDirectory: scratch
                )
            }
            #expect(!FileManager.default.fileExists(atPath: scratch.path(percentEncoded: false)))
        }
    }

    @Test("A conflicting SDK link is preserved and rejected")
    func rejectsConflictingLink() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKSearchPath") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let bundle = try createBundle(identifier: identifier, in: directory)
            let selection = try SDKSelectionDirectory.resolve(
                sdkIdentifier: identifier,
                sdkBundleURL: bundle,
                scratchDirectory: scratch
            )
            let link = selection.appending(path: bundle.lastPathComponent)
            try FileManager.default.removeItem(at: link)
            let conflictingBundle = try createBundle(identifier: "conflicting", in: directory)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: conflictingBundle)

            #expect(throws: SDKSelectionDirectory.Error.unexpectedItem(link.path(percentEncoded: false))) {
                try SDKSelectionDirectory.resolve(
                    sdkIdentifier: identifier,
                    sdkBundleURL: bundle,
                    scratchDirectory: scratch
                )
            }
            #expect(
                link.resolvingSymlinksInPath().pathComponents
                    == conflictingBundle.resolvingSymlinksInPath().pathComponents
            )
        }
    }

}

private final class LosingSelectionRaceFileManager: FileManager, @unchecked Sendable {

    override func createSymbolicLink(at url: URL, withDestinationURL destURL: URL) throws {
        try super.createSymbolicLink(at: url, withDestinationURL: destURL)
        throw CocoaError(.fileWriteFileExists)
    }

}

private func createBundle(identifier: String, in directory: URL) throws -> URL {

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bundle = directory.appending(
        path: "\(identifier).artifactbundle",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    return bundle
}
