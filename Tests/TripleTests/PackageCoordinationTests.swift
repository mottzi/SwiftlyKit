import CryptoKit
import Foundation
import Testing
@testable import Triple

@Suite("Package coordination")
struct PackageCoordinationTests {

    @Test("Sibling readers overlap configuration and exclude removal until all readers exit")
    func siblingReaders() async throws {

        try await withTemporaryDirectory(prefix: "Triple-sibling-readers") { directory in
            let lockFile = directory.appending(path: "mutation.lock")
            let firstReady = directory.appending(path: "first.ready")
            let secondReady = directory.appending(path: "second.ready")
            let first = try CoordinationLockProcess(lockFile: lockFile, readyFile: firstReady, shared: true)
            defer { first.terminate() }
            let second = try CoordinationLockProcess(lockFile: lockFile, readyFile: secondReady, shared: true)
            defer { second.terminate() }
            try await waitForCoordinationFile(firstReady)
            try await waitForCoordinationFile(secondReady)

            let gate = MutationGate(lockFile: lockFile)
            let configured = CoordinationEntry()
            let configuration = Task {
                try await gate.withReadAccess { await configured.enter() }
            }
            defer { configuration.cancel() }
            let deadline = ContinuousClock.now + .seconds(1)
            while await !configured.didEnter, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await configured.didEnter)

            let removed = CoordinationEntry()
            let removal = Task {
                try await gate.withAccess { await removed.enter() }
            }
            defer { removal.cancel() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await !removed.didEnter)
            first.terminate()
            try await Task.sleep(for: .milliseconds(100))
            #expect(await !removed.didEnter)
            second.terminate()

            try await configuration.value
            try await removal.value
            #expect(await removed.didEnter)
        }
    }

    @Test("Sibling removal excludes configuration readers until its lease ends")
    func siblingRemoval() async throws {

        try await withTemporaryDirectory(prefix: "Triple-sibling-removal") { directory in
            let lockFile = directory.appending(path: "mutation.lock")
            let ready = directory.appending(path: "removal.ready")
            let holder = try CoordinationLockProcess(lockFile: lockFile, readyFile: ready, shared: false)
            defer { holder.terminate() }
            try await waitForCoordinationFile(ready)

            let configured = CoordinationEntry()
            let reader = Task {
                try await MutationGate(lockFile: lockFile).withReadAccess { await configured.enter() }
            }
            defer { reader.cancel() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await !configured.didEnter)
            holder.terminate()
            try await reader.value
            #expect(await configured.didEnter)
        }
    }

    @Test("Different packages sharing scratch storage exclude each other across processes")
    func siblingSharedScratch() async throws {

        try await withTemporaryDirectory(prefix: "Triple-sibling-scratch") { directory in
            let gate = MutationGate(lockFile: directory.appending(path: "mutation.lock"))
            let firstEnvironment = Self.environment(root: directory.appending(path: "First"))
            let secondEnvironment = Self.environment(root: directory.appending(path: "Second"))
            let scratch = directory.appending(path: "Scratch")
            let storage = SwiftPMScratchStorage.directory(scratch)
            try await gate.withPackageAccess(using: firstEnvironment, scratchStorage: storage) { }
            let scratchLock = try Self.pathLock(for: scratch, in: directory)
            try #require(FileManager.default.fileExists(atPath: scratchLock.path(percentEncoded: false)))
            let ready = directory.appending(path: "scratch.ready")
            let holder = try CoordinationLockProcess(lockFile: scratchLock, readyFile: ready, shared: false)
            defer { holder.terminate() }
            try await waitForCoordinationFile(ready)

            let built = CoordinationEntry()
            let second = Task {
                try await gate.withPackageAccess(using: secondEnvironment, scratchStorage: storage) {
                    await built.enter()
                }
            }
            defer { second.cancel() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await !built.didEnter)

            let configured = CoordinationEntry()
            let configuration = Task {
                try await gate.withConfigurationAccess(using: secondEnvironment, scratchStorage: storage) {
                    await configured.enter()
                }
            }
            defer { configuration.cancel() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await !configured.didEnter)

            holder.terminate()
            try await second.value
            try await configuration.value
            #expect(await built.didEnter)
            #expect(await configured.didEnter)
        }
    }

    @Test("A parent scratch reset excludes another package's nested scratch directory")
    func nestedScratch() async throws {

        try await withTemporaryDirectory(prefix: "Triple-nested-scratch") { directory in
            let parent = directory.appending(path: "Scratch")
            try await Self.expectPackageExclusion(
                in: directory,
                holding: .directory(parent),
                accessing: .directory(parent.appending(path: "Nested"))
            )
        }
    }

    @Test("An export into another package's scratch directory excludes resetting its ancestor")
    func exportResetOverlap() async throws {

        try await withTemporaryDirectory(prefix: "Triple-export-reset") { directory in
            let scratch = directory.appending(path: "Scratch")
            try await Self.expectPackageExclusion(
                in: directory,
                holding: .directory(directory.appending(path: "ExporterScratch")),
                output: .export(to: scratch.appending(path: "Output")),
                accessing: .directory(scratch)
            )
        }
    }

    @Test("Symbolic-link aliases cannot bypass an occupied scratch directory")
    func symbolicScratchAlias() async throws {

        try await withTemporaryDirectory(prefix: "Triple-scratch-alias") { directory in
            let scratch = directory.appending(path: "Scratch")
            let alias = directory.appending(path: "Alias")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: scratch)
            try await Self.expectPackageExclusion(
                in: directory,
                holding: .directory(scratch),
                accessing: .directory(alias)
            )
        }
    }

    @Test("Case aliases on a case-insensitive volume cannot bypass an occupied scratch directory")
    func caseInsensitiveScratchAlias() async throws {

        try await withTemporaryDirectory(prefix: "Triple-scratch-case") { directory in
            let scratch = directory.appending(path: "Scratch")
            let alias = directory.appending(path: "scratch")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            guard FileManager.default.fileExists(atPath: alias.path(percentEncoded: false)) else { return }
            try await Self.expectPackageExclusion(
                in: directory,
                holding: .directory(scratch),
                accessing: .directory(alias)
            )
        }
    }

    @Test("Unicode normalization aliases cannot bypass an occupied scratch directory")
    func unicodeScratchAlias() async throws {

        try await withTemporaryDirectory(prefix: "Triple-scratch-unicode") { directory in
            let scratch = directory.appending(path: "Caf\u{00E9}")
            let alias = directory.appending(path: "Cafe\u{0301}")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            guard FileManager.default.fileExists(atPath: alias.path(percentEncoded: false)) else { return }
            try await Self.expectPackageExclusion(
                in: directory,
                holding: .directory(scratch),
                accessing: .directory(alias)
            )
        }
    }

    @Test("Installed tools admit concurrent readers and exclude removal until every reader leaves")
    func concurrentReaders() async throws {

        try await withTemporaryDirectory(prefix: "Triple-readers") { directory in
            let gate = MutationGate(lockFile: directory.appending(path: "mutation.lock"))
            let release = AsyncStream<Void>.makeStream()
            let entered = AsyncStream<Void>.makeStream()
            let first = Task {
                try await gate.withReadAccess {
                    entered.continuation.yield()
                    for await _ in release.stream { break }
                }
            }
            for await _ in entered.stream { break }
            try await gate.withReadAccess { }

            let tracker = CoordinationEntry()
            let removal = Task {
                try await gate.withAccess { await tracker.enter() }
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await !tracker.didEnter)
            release.continuation.yield()
            try await first.value
            try await removal.value
            #expect(await tracker.didEnter)
        }
    }

    @Test("Another package and root configuration proceed while a package build holds its lease")
    func independentConfiguration() async throws {

        try await withTemporaryDirectory(prefix: "Triple-package-coordination") { directory in
            let gate = MutationGate(lockFile: directory.appending(path: "mutation.lock"))
            let firstEnvironment = Self.environment(root: directory.appending(path: "First"))
            let secondEnvironment = Self.environment(root: directory.appending(path: "Second"))
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let build = Task {
                try await gate.withPackageAccess(using: firstEnvironment, scratchStorage: .packageDefault) {
                    entered.continuation.yield()
                    for await _ in release.stream { break }
                }
            }
            for await _ in entered.stream { break }

            try await gate.withPackageAccess(using: secondEnvironment, scratchStorage: .packageDefault) { }
            try await gate.withConfigurationAccess(
                using: firstEnvironment,
                scratchStorage: .directory(directory.appending(path: "Configuration"))
            ) { }

            let queued = Task {
                try await gate.withPackageAccess(using: firstEnvironment, scratchStorage: .packageDefault) {
                    Issue.record("A cancelled operation must not enter an occupied package.")
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            queued.cancel()
            await #expect(throws: CancellationError.self) { try await queued.value }
            release.continuation.yield()
            try await build.value
            try await gate.withPackageAccess(using: firstEnvironment, scratchStorage: .packageDefault) { }
        }
    }

    private static func environment(root: URL) -> LocalBuildEnvironment {

        LocalBuildEnvironment(
            swiftVersion: SwiftVersion(major: 6, minor: 3, patch: 3),
            staticLinuxSDK: StaticLinuxSDK(identifier: "test", version: "test"),
            packageRoot: root,
            swiftly: SwiftlyInstallation(executableURL: root.appending(path: "swiftly")),
            sdkBundleURL: root.appending(path: "sdk.artifactbundle"),
            target: .linux(.x86_64),
            swiftPMEnvironment: SwiftPMEnvironment.inherited.snapshot()
        )
    }

    private static func expectPackageExclusion(
        in directory: URL,
        holding heldStorage: SwiftPMScratchStorage,
        output: BuildOutput = .buildStorage,
        accessing queuedStorage: SwiftPMScratchStorage
    ) async throws {

        let gate = MutationGate(lockFile: directory.appending(path: "mutation.lock"))
        let first = environment(root: directory.appending(path: "First"))
        let second = environment(root: directory.appending(path: "Second"))
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await gate.withPackageAccess(using: first, scratchStorage: heldStorage, output: output) {
                entered.continuation.yield()
                for await _ in release.stream { break }
            }
        }
        defer {
            holder.cancel()
            release.continuation.finish()
        }
        for await _ in entered.stream { break }

        let tracker = CoordinationEntry()
        let queued = Task {
            try await gate.withPackageAccess(using: second, scratchStorage: queuedStorage) {
                await tracker.enter()
            }
        }
        defer { queued.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !tracker.didEnter)
        release.continuation.yield()
        try await holder.value
        try await queued.value
        #expect(await tracker.didEnter)
    }

    /// Derives the documented persistent path-lock filename for a cooperating sibling process.
    private static func pathLock(for url: URL, in directory: URL) throws -> URL {

        var identity = try CanonicalFileURL.resolve(url).path(percentEncoded: false)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        while identity.count > 1 && identity.hasSuffix("/") { identity.removeLast() }
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "path-\(digest).lock")
    }

}

private actor CoordinationEntry {

    private(set) var didEnter = false

    func enter() {
        didEnter = true
    }

}

/// A test-owned sibling process holding the same advisory lock protocol as Triple.
private struct CoordinationLockProcess {

    private let process: Process

    init(lockFile: URL, readyFile: URL, shared: Bool) throws {

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, os, sys, time
            descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            access = fcntl.LOCK_SH if sys.argv[3] == "shared" else fcntl.LOCK_EX
            fcntl.flock(descriptor, access)
            os.close(os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
            time.sleep(30)
            """,
            lockFile.path(percentEncoded: false),
            readyFile.path(percentEncoded: false),
            shared ? "shared" : "exclusive"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    func terminate() {

        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

}

private func waitForCoordinationFile(_ file: URL) async throws {

    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
}
