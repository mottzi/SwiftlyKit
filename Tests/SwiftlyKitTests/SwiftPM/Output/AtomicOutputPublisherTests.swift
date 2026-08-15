import Darwin
import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Atomic runnable output publication")
struct AtomicOutputPublisherTests {

    @Test("Publishes one executable-only directory and returns its launch URL")
    func executableOnly() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Publisher") { directory in
            let source = directory.appending(path: "Tool")
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)
            try Data("executable".utf8).write(to: source)

            let result = try await AtomicOutputPublisher.publish(
                SwiftPMBuildOutput(executable: source, resourceBundles: []),
                to: destination
            )

            #expect(result == destination.appending(path: "Tool"))
            #expect(try Data(contentsOf: result) == Data("executable".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path()) == ["Tool"])
        }
    }

    @Test("Publishes the executable and exact resource bundles as siblings")
    func resources() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Publisher") { directory in
            let build = directory.appending(path: "build", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
            let executable = build.appending(path: "Tool")
            try Data("executable".utf8).write(to: executable)
            let bundle = try createPublisherBundle(named: "Package_Assets.resources", in: build)
            try Data("asset".utf8).write(to: bundle.appending(path: "asset.txt"))
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)

            let result = try await AtomicOutputPublisher.publish(
                SwiftPMBuildOutput(executable: executable, resourceBundles: [bundle]),
                to: destination,
                prepareExecutable: { stagedExecutable in
                    try Data("prepared executable".utf8).write(to: stagedExecutable)
                }
            )

            #expect(result == destination.appending(path: "Tool"))
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path())) == [
                "Tool",
                "Package_Assets.resources"
            ])
            #expect(try Data(contentsOf: result) == Data("prepared executable".utf8))
            let publishedAsset = destination.appending(path: "Package_Assets.resources/asset.txt")
            #expect(try Data(contentsOf: publishedAsset) == Data("asset".utf8))
            #expect(try Data(contentsOf: bundle.appending(path: "asset.txt")) == Data("asset".utf8))
        }
    }

    @Test("Concurrent create-only publications have one winner")
    func concurrentCreate() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Publisher") { directory in
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)
            let sources = ["first", "second"].map { directory.appending(path: $0) }
            for source in sources { try Data(source.lastPathComponent.utf8).write(to: source) }

            let attempts = await withTaskGroup(of: PublicationAttempt.self) { group in
                for source in sources {
                    group.addTask {
                        do {
                            _ = try await AtomicOutputPublisher.publish(
                                SwiftPMBuildOutput(executable: source, resourceBundles: []),
                                to: destination
                            )
                            return .published
                        } catch let error as SwiftPMError {
                            return .rejected(error)
                        } catch {
                            return .unexpected
                        }
                    }
                }

                return await group.reduce(into: []) { $0.append($1) }
            }

            #expect(attempts.filter(\.wasPublished).count == 1)
            #expect(attempts.filter(\.wasRejectedAsExisting).count == 1)
        }
    }

    @Test("Replacement atomically swaps a nonempty prior directory")
    func replacement() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Publisher") { directory in
            let source = directory.appending(path: "Tool")
            try Data("new".utf8).write(to: source)
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("old".utf8).write(to: destination.appending(path: "OldTool"))

            _ = try await AtomicOutputPublisher.publish(
                SwiftPMBuildOutput(executable: source, resourceBundles: []),
                to: destination,
                replacingExisting: true
            )

            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path()) == ["Tool"])
            #expect(try Data(contentsOf: destination.appending(path: "Tool")) == Data("new".utf8))
        }
    }

    @Test("Preparation failure preserves the prior destination and removes staging")
    func preparationFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Publisher") { directory in
            let source = directory.appending(path: "Tool")
            try Data("new".utf8).write(to: source)
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("old".utf8).write(to: destination.appending(path: "Tool"))

            await #expect(throws: PublicationPreparationError.failed) {
                try await AtomicOutputPublisher.publish(
                    SwiftPMBuildOutput(executable: source, resourceBundles: []),
                    to: destination,
                    replacingExisting: true,
                    prepareExecutable: { _ in throw PublicationPreparationError.failed }
                )
            }

            #expect(try Data(contentsOf: destination.appending(path: "Tool")) == Data("old".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path()).allSatisfy {
                !$0.hasPrefix(".Published.swiftlykit-")
            })
        }
    }

    @Test("Symbolic links, hard links, and special resource entries are rejected before publication")
    func unsafeResource() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Publisher") { directory in
            let build = directory.appending(path: "build", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
            let executable = build.appending(path: "Tool")
            try Data("executable".utf8).write(to: executable)
            let bundle = try createPublisherBundle(named: "Package_Assets.resources", in: build)
            try FileManager.default.createSymbolicLink(
                at: bundle.appending(path: "linked"),
                withDestinationURL: executable
            )
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)

            await #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try await AtomicOutputPublisher.publish(
                    SwiftPMBuildOutput(executable: executable, resourceBundles: [bundle]),
                    to: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path()))

            try FileManager.default.removeItem(at: bundle.appending(path: "linked"))
            let asset = bundle.appending(path: "asset")
            try Data("asset".utf8).write(to: asset)
            try FileManager.default.linkItem(at: asset, to: bundle.appending(path: "hard-linked"))
            await #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try await AtomicOutputPublisher.publish(
                    SwiftPMBuildOutput(executable: executable, resourceBundles: [bundle]),
                    to: destination
                )
            }

            try FileManager.default.removeItem(at: bundle.appending(path: "hard-linked"))
            let pipe = bundle.appending(path: "pipe")
            #expect(mkfifo(pipe.path(percentEncoded: false), 0o600) == 0)
            await #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try await AtomicOutputPublisher.publish(
                    SwiftPMBuildOutput(executable: executable, resourceBundles: [bundle]),
                    to: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path()))
        }
    }

    @Test("Staged resource validation withholds a tree changed during executable preparation")
    func stagedValidation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Publisher") { directory in
            let build = directory.appending(path: "build", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
            let executable = build.appending(path: "Tool")
            try Data("executable".utf8).write(to: executable)
            let bundle = try createPublisherBundle(named: "Package_Assets.resources", in: build)
            try Data("asset".utf8).write(to: bundle.appending(path: "asset"))
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)

            await #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try await AtomicOutputPublisher.publish(
                    SwiftPMBuildOutput(executable: executable, resourceBundles: [bundle]),
                    to: destination,
                    prepareExecutable: { stagedExecutable in
                        let stagedBundle = stagedExecutable
                            .deletingLastPathComponent()
                            .appending(path: bundle.lastPathComponent, directoryHint: .isDirectory)
                        try FileManager.default.createSymbolicLink(
                            at: stagedBundle.appending(path: "linked"),
                            withDestinationURL: stagedExecutable
                        )
                    }
                )
            }

            #expect(!FileManager.default.fileExists(atPath: destination.path()))
        }
    }

}

private func createPublisherBundle(named name: String, in directory: URL) throws -> URL {

    let bundle = directory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    return bundle
}

private enum PublicationPreparationError: Error {
    case failed
}

private enum PublicationAttempt {

    case published
    case rejected(SwiftPMError)
    case unexpected

    var wasPublished: Bool {
        if case .published = self { return true }
        return false
    }

    var wasRejectedAsExisting: Bool {
        if case .rejected(.outputAlreadyExists) = self { return true }
        return false
    }

}
