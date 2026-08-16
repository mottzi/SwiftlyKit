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

    @Test("A nested observed root overrides an enclosing event exclusion")
    func nestedRootOverridesExclusion() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SourceStability") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let dependency = scratch.appending(path: "Dependency", directoryHint: .isDirectory)
            let source = dependency.appending(path: "Sources/Tool/main.swift")
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let original = Data("print(1)\n".utf8)
            try original.write(to: source)
            let stability = try await PackageSourceStability.start(
                roots: [directory, dependency],
                excluding: [scratch]
            )

            try Data("print(2)\n".utf8).write(to: source)
            try original.write(to: source)

            await #expect(throws: PackageSourceStabilityError.sourceChanged) {
                try await stability.finish()
            }
        }
    }

    @Test("Final evidence re-resolves symbolic-link roots")
    func recanonicalizesRoots() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SourceStability") { directory in
            let first = directory.appending(path: "First", directoryHint: .isDirectory)
            let second = directory.appending(path: "Second", directoryHint: .isDirectory)
            let rootLink = directory.appending(path: "Root", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try Data("first\n".utf8).write(to: first.appending(path: "source.swift"))
            try Data("second\n".utf8).write(to: second.appending(path: "source.swift"))
            try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: first)
            let stability = try await PackageSourceStability.start(roots: [rootLink])

            try FileManager.default.removeItem(at: rootLink)
            try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: second)

            await #expect(throws: PackageSourceStabilityError.sourceChanged) {
                try await stability.finish()
            }
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
