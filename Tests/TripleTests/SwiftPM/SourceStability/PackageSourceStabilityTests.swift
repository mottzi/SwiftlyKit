import Darwin
import Foundation
import Testing
@testable import Triple

@Suite("Package source stability")
struct PackageSourceStabilityTests {

    @Test("Large graphs retain source checks and nested exclusions with a normal app descriptor limit", .serialized, arguments: [false, true])
    func largeGraphObservation(changesSource: Bool) async throws {

        var previousLimit: rlimit?
        defer { if var previousLimit { _ = setrlimit(RLIMIT_NOFILE, &previousLimit) } }
        if let expected = ProcessInfo.processInfo.environment["TRIPLE_TEST_SOURCE_DESCRIPTOR_LIMIT"].flatMap(UInt64.init) {
            var limit = rlimit()
            try #require(getrlimit(RLIMIT_NOFILE, &limit) == 0)
            previousLimit = limit
            limit.rlim_cur = min(limit.rlim_cur, expected)
            try #require(setrlimit(RLIMIT_NOFILE, &limit) == 0)
            try #require(getrlimit(RLIMIT_NOFILE, &limit) == 0)
            #expect(limit.rlim_cur <= expected)
        }
        try await withTemporaryDirectory(prefix: "Triple-LargeSourceGraph") { directory in
            let scratch = directory.appending(path: ".build")
            var roots = [directory]
            for index in 0..<120 {
                let dependency = scratch.appending(path: "checkouts/Dependency-\(index)")
                try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
                try Data("print(1)\n".utf8).write(to: dependency.appending(path: "source.swift"))
                roots.append(dependency)
            }
            let last = try #require(roots.last)
            let nested = last.appending(path: ".build/NestedDependency")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let source = nested.appending(path: "source.swift")
            let original = Data("print(1)\n".utf8)
            try original.write(to: source)
            roots.append(nested)
            if previousLimit != nil {
                let scope = try PackageSourceScope(roots: roots, excluding: [scratch])
                print("SOURCE_MONITOR_ANCHOR_COUNTS \(scope.eventStreamGroups.map { $0.watchRoots.count })")
            }
            let stability = try await PackageSourceStability.start(roots: roots, excluding: [scratch])

            let git = last.appending(path: ".git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            try Data("ignored metadata".utf8).write(to: git.appending(path: "HEAD"))
            try Data("ignored artifact".utf8).write(to: scratch.appending(path: "output.o"))
            if changesSource {
                try Data("print(2)\n".utf8).write(to: source)
                try original.write(to: source)
                await #expect(throws: PackageSourceStabilityError.sourceChanged) {
                    try await stability.finish()
                }
            } else {
                try await stability.finish()
            }
        }
    }

    @Test("Moving and restoring a coalesced watch ancestor invalidates the source evidence")
    func coalescedAncestorChanges() async throws {

        try await withTemporaryDirectory(prefix: "Triple-SourceAncestor") { directory in
            let parent = directory.appending(path: "Checkouts")
            let first = parent.appending(path: "First")
            let second = parent.appending(path: "Second")
            for root in [first, second] {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("print(1)\n".utf8).write(to: root.appending(path: "source.swift"))
            }
            let stability = try await PackageSourceStability.start(roots: [directory, first, second])
            let moved = directory.appending(path: "MovedCheckouts")
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.moveItem(at: moved, to: parent)
            await #expect(throws: PackageSourceStabilityError.self) {
                try await stability.finish()
            }
        }
    }

    @Test("A source change followed by restoration still fails the observation")
    func changeThenRestore() async throws {

        try await withTemporaryDirectory(prefix: "Triple-SourceStability") { directory in
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

        try await withTemporaryDirectory(prefix: "Triple-SourceStability") { directory in
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

        try await withTemporaryDirectory(prefix: "Triple-SourceStability") { directory in
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

        try await withTemporaryDirectory(prefix: "Triple-SourceStability") { directory in
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

    @Test("Build-output traffic preserves package and nested dependency observation", arguments: [0, 1, 2])
    func buildOutputTraffic(changedRoot: Int) async throws {

        try await withTemporaryDirectory(prefix: "Triple-SourceTraffic") { directory in
            let scratch = directory.appending(path: ".build")
            let output = scratch.appending(path: "out")
            let dependency = scratch.appending(path: "checkouts/Dependency")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
            let source = directory.appending(path: "main.swift")
            let dependencySource = dependency.appending(path: "main.swift")
            let original = Data("print(1)\n".utf8)
            try original.write(to: source)
            try original.write(to: dependencySource)
            let stability = try await PackageSourceStability.start(
                roots: [directory, dependency],
                excluding: [scratch]
            )

            for index in 0..<6000 {
                try Data("object".utf8).write(to: output.appending(path: "object-\(index)"))
                if index == 3000, changedRoot != 0 {
                    let changedSource = changedRoot == 1 ? source : dependencySource
                    try Data("print(2)\n".utf8).write(to: changedSource)
                    try original.write(to: changedSource)
                }
            }

            if changedRoot == 0 {
                try await stability.finish()
            } else {
                await #expect(throws: PackageSourceStabilityError.sourceChanged) {
                    try await stability.finish()
                }
            }
        }
    }

    @Test("Cancellation remains CancellationError while observation starts")
    func cancellation() async throws {

        try await withTemporaryDirectory(prefix: "Triple-SourceStability") { directory in
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
