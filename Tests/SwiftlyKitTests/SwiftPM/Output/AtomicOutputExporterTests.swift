import Darwin
import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Atomic runnable output export")
struct AtomicOutputExporterTests {

    @Test("Exports one executable-only directory and returns its build result")
    func executableOnly() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Exporter") { directory in
            let source = directory.appending(path: "Tool")
            let destination = directory.appending(path: "Exported", directoryHint: .isDirectory)
            try Data("executable".utf8).write(to: source)

            let result = try await AtomicOutputExporter.export(
                executable: source,
                executableName: "Tool",
                resourceBundles: [],
                architecture: .x86_64,
                to: destination
            )

            #expect(result.executable == destination.appending(path: "Tool"))
            #expect(result.executableName == "Tool")
            #expect(result.resourceBundles.isEmpty)
            #expect(result.directory == destination)
            #expect(try Data(contentsOf: result.executable) == Data("executable".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path()) == ["Tool"])
        }
    }

    @Test("Exports the executable and exact resource bundles as siblings")
    func resources() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Exporter") { directory in
            let build = directory.appending(path: "build", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
            let executable = build.appending(path: "Tool")
            try Data("executable".utf8).write(to: executable)
            let bundle = try createExporterBundle(named: "Package_Assets.resources", in: build)
            try Data("asset".utf8).write(to: bundle.appending(path: "asset.txt"))
            let destination = directory.appending(path: "Exported", directoryHint: .isDirectory)

            let result = try await AtomicOutputExporter.export(
                executable: executable,
                executableName: "Tool",
                resourceBundles: [bundle],
                architecture: .x86_64,
                to: destination,
                prepareExecutable: { stagedExecutable in
                    try Data("prepared executable".utf8).write(to: stagedExecutable)
                }
            )

            #expect(result.executable == destination.appending(path: "Tool"))
            #expect(result.resourceBundles == [
                destination.appending(path: "Package_Assets.resources", directoryHint: .isDirectory)
            ])
            #expect(result.directory == destination)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path())) == [
                "Tool",
                "Package_Assets.resources"
            ])
            #expect(try Data(contentsOf: result.executable) == Data("prepared executable".utf8))
            let exportedAsset = destination.appending(path: "Package_Assets.resources/asset.txt")
            #expect(try Data(contentsOf: exportedAsset) == Data("asset".utf8))
            #expect(try Data(contentsOf: bundle.appending(path: "asset.txt")) == Data("asset".utf8))
        }
    }

    @Test("Concurrent create-only exports have one winner")
    func concurrentCreate() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Exporter") { directory in
            let destination = directory.appending(path: "Exported", directoryHint: .isDirectory)
            let sources = ["first", "second"].map { directory.appending(path: $0) }
            for source in sources { try Data(source.lastPathComponent.utf8).write(to: source) }

            let attempts = await withTaskGroup(of: ExportAttempt.self) { group in
                for source in sources {
                    group.addTask {
                        do {
                            _ = try await AtomicOutputExporter.export(
                                executable: source,
                                executableName: "Tool",
                                resourceBundles: [],
                                architecture: .x86_64,
                                to: destination
                            )
                            return .exported
                        } catch let error as SwiftPMError {
                            return .rejected(error)
                        } catch {
                            return .unexpected
                        }
                    }
                }

                return await group.reduce(into: []) { $0.append($1) }
            }

            #expect(attempts.filter(\.wasExported).count == 1)
            #expect(attempts.filter(\.wasRejectedAsExisting).count == 1)
        }
    }

    @Test("Replacement atomically swaps a nonempty prior directory")
    func replacement() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Exporter") { directory in
            let source = directory.appending(path: "Tool")
            try Data("new".utf8).write(to: source)
            let destination = directory.appending(path: "Exported", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("old".utf8).write(to: destination.appending(path: "OldTool"))

            _ = try await AtomicOutputExporter.export(
                executable: source,
                executableName: "Tool",
                resourceBundles: [],
                architecture: .x86_64,
                to: destination,
                destinationPolicy: .replaceIfPresent
            )

            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path()) == ["Tool"])
            #expect(try Data(contentsOf: destination.appending(path: "Tool")) == Data("new".utf8))
        }
    }

    @Test("Existing-empty policy preserves contents added while output is staged")
    func destinationBecomesNonemptyDuringPreparation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Exporter") { directory in
            let source = directory.appending(path: "Tool")
            try Data("executable".utf8).write(to: source)
            let destination = directory.appending(path: "Exported", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let unrelatedFile = destination.appending(path: "keep.txt")

            await #expect(throws: SwiftPMError.outputAlreadyExists(destination)) {
                try await AtomicOutputExporter.export(
                    executable: source,
                    executableName: "Tool",
                    resourceBundles: [],
                    architecture: .x86_64,
                    to: destination,
                    destinationPolicy: .requireExistingEmptyDirectory,
                    prepareExecutable: { _ in
                        try Data("keep".utf8).write(to: unrelatedFile)
                    }
                )
            }

            #expect(try Data(contentsOf: unrelatedFile) == Data("keep".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path()) == ["keep.txt"])
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path())) == ["Tool", "Exported"])
        }
    }

    @Test("Preparation failure preserves the prior destination and removes staging")
    func preparationFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Exporter") { directory in
            let source = directory.appending(path: "Tool")
            try Data("new".utf8).write(to: source)
            let destination = directory.appending(path: "Exported", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("old".utf8).write(to: destination.appending(path: "Tool"))

            await #expect(throws: ExportPreparationError.failed) {
                try await AtomicOutputExporter.export(
                    executable: source,
                    executableName: "Tool",
                    resourceBundles: [],
                    architecture: .x86_64,
                    to: destination,
                    destinationPolicy: .replaceIfPresent,
                    prepareExecutable: { _ in throw ExportPreparationError.failed }
                )
            }

            #expect(try Data(contentsOf: destination.appending(path: "Tool")) == Data("old".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path()).allSatisfy {
                !$0.hasPrefix(".Exported.swiftlykit-")
            })
        }
    }

    @Test("Symbolic links, hard links, and special resource entries are rejected before export")
    func unsafeResource() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Exporter") { directory in
            let build = directory.appending(path: "build", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
            let executable = build.appending(path: "Tool")
            try Data("executable".utf8).write(to: executable)
            let bundle = try createExporterBundle(named: "Package_Assets.resources", in: build)
            try FileManager.default.createSymbolicLink(
                at: bundle.appending(path: "linked"),
                withDestinationURL: executable
            )
            let destination = directory.appending(path: "Exported", directoryHint: .isDirectory)

            await #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try await AtomicOutputExporter.export(
                    executable: executable,
                    executableName: "Tool",
                    resourceBundles: [bundle],
                    architecture: .x86_64,
                    to: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path()))

            try FileManager.default.removeItem(at: bundle.appending(path: "linked"))
            let asset = bundle.appending(path: "asset")
            try Data("asset".utf8).write(to: asset)
            try FileManager.default.linkItem(at: asset, to: bundle.appending(path: "hard-linked"))
            await #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try await AtomicOutputExporter.export(
                    executable: executable,
                    executableName: "Tool",
                    resourceBundles: [bundle],
                    architecture: .x86_64,
                    to: destination
                )
            }

            try FileManager.default.removeItem(at: bundle.appending(path: "hard-linked"))
            let pipe = bundle.appending(path: "pipe")
            #expect(mkfifo(pipe.path(percentEncoded: false), 0o600) == 0)
            await #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try await AtomicOutputExporter.export(
                    executable: executable,
                    executableName: "Tool",
                    resourceBundles: [bundle],
                    architecture: .x86_64,
                    to: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path()))
        }
    }

    @Test("Staged resource validation withholds a tree changed during executable preparation")
    func stagedValidation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Exporter") { directory in
            let build = directory.appending(path: "build", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
            let executable = build.appending(path: "Tool")
            try Data("executable".utf8).write(to: executable)
            let bundle = try createExporterBundle(named: "Package_Assets.resources", in: build)
            try Data("asset".utf8).write(to: bundle.appending(path: "asset"))
            let destination = directory.appending(path: "Exported", directoryHint: .isDirectory)

            await #expect(throws: SwiftPMError.runtimeResourceVerificationFailed) {
                try await AtomicOutputExporter.export(
                    executable: executable,
                    executableName: "Tool",
                    resourceBundles: [bundle],
                    architecture: .x86_64,
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

private func createExporterBundle(named name: String, in directory: URL) throws -> URL {

    let bundle = directory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    return bundle
}

private enum ExportPreparationError: Error {
    case failed
}

private enum ExportAttempt {

    case exported
    case rejected(SwiftPMError)
    case unexpected

    var wasExported: Bool {
        if case .exported = self { return true }
        return false
    }

    var wasRejectedAsExisting: Bool {
        if case .rejected(.outputAlreadyExists) = self { return true }
        return false
    }

}
