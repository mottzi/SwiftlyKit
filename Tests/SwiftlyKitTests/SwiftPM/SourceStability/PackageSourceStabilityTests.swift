import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Package source stability")
struct PackageSourceStabilityTests {

    @Test("A source change followed by restoration still fails the observation")
    func changeThenRestore() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SourceStability") { directory in
            let source = directory.appending(path: "Sources/Tool/main.swift")
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let original = Data("print(1)\n".utf8)
            try original.write(to: source)
            let stability = try await PackageSourceStability.start(roots: [directory])

            try Data("print(2)\n".utf8).write(to: source)
            try original.write(to: source)

            await #expect(throws: PackageSourceStabilityError.sourceChanged) {
                try await stability.finish()
            }
        }
    }

    @Test("Changes in excluded scratch storage do not fail the observation")
    func excludedScratch() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SourceStability") { directory in
            let source = directory.appending(path: "Sources/Tool/main.swift")
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data("print(1)\n".utf8).write(to: source)
            let stability = try await PackageSourceStability.start(
                roots: [directory],
                excluding: [scratch]
            )

            try Data("build state".utf8).write(to: scratch.appending(path: "state"))

            try await stability.finish()
        }
    }

    @Test("Cancellation remains CancellationError while observation starts")
    func cancellation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SourceStability") { directory in
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await PackageSourceStability.start(roots: [directory])
            }

            await #expect(throws: CancellationError.self) {
                try await task.value
            }
        }
    }

}
