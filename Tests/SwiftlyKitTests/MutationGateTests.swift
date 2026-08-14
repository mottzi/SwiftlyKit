import Darwin
import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Mutation gate")
struct MutationGateTests {

    @Test("A sibling process owns the mutation lease until it exits")
    func siblingProcessLease() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let lockFile = directory.appending(path: "mutation.lock")
            let readyFile = directory.appending(path: "holder.ready")
            let holder = try SiblingLockHolder(lockFile: lockFile, readyFile: readyFile)
            defer { holder.terminate() }
            try await waitForFile(readyFile)

            let gate = MutationGate(lockFile: lockFile)
            let tracker = EntryTracker()
            let waiter = Task {
                try await gate.withAccess { await tracker.enter() }
            }

            try await Task.sleep(for: .milliseconds(100))
            #expect(await !tracker.didEnter)

            holder.terminate()
            try await waiter.value

            #expect(await tracker.didEnter)
        }
    }

    @Test("A sibling public workflow uses the production mutation lease")
    func siblingPublicWorkflow() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let startedFile = directory.appending(path: "fixture.started")
            let outcomeFile = directory.appending(path: "fixture.outcome")
            let invalidPackage = directory.appending(path: "missing-package")

            let fixture = try await MutationGate.shared.withAccess {
                let fixture = try PublicMutationFixture(
                    invalidPackage: invalidPackage,
                    startedFile: startedFile,
                    outcomeFile: outcomeFile
                )
                try await waitForFile(startedFile)
                try await Task.sleep(for: .milliseconds(100))

                #expect(fixture.isRunning)
                #expect(!FileManager.default.fileExists(atPath: outcomeFile.path(percentEncoded: false)))

                return fixture
            }
            defer { fixture.terminate() }

            try await fixture.waitUntilExit()

            let outcome = try String(contentsOf: outcomeFile, encoding: .utf8)
            #expect(outcome == "invalid-package-root")

            let coordinationFile = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "SwiftlyKit/Coordination/v1/mutation.lock")
            #expect(FileManager.default.fileExists(atPath: coordinationFile.path(percentEncoded: false)))
        }
    }

    @Test("A cancelled sibling-process waiter does not enter the mutation")
    func siblingProcessCancellation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let lockFile = directory.appending(path: "mutation.lock")
            let readyFile = directory.appending(path: "holder.ready")
            let holder = try SiblingLockHolder(lockFile: lockFile, readyFile: readyFile)
            defer { holder.terminate() }
            try await waitForFile(readyFile)

            let tracker = EntryTracker()
            let waiter = Task {
                try await MutationGate(lockFile: lockFile).withAccess { await tracker.enter() }
            }
            try await Task.sleep(for: .milliseconds(100))
            waiter.cancel()

            await #expect(throws: CancellationError.self) {
                try await waiter.value
            }
            #expect(await !tracker.didEnter)
        }
    }

    @Test("Coordination setup failures use the public error family")
    func setupFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let nonDirectory = directory.appending(path: "not-a-directory")
            try Data().write(to: nonDirectory)
            let lockFile = nonDirectory.appending(path: "mutation.lock")

            do {
                try await MutationGate(lockFile: lockFile).withAccess { }
                Issue.record("An unusable coordination directory must fail.")
            } catch let error as SwiftlyKitError {
                guard case .mutationCoordinationFailed = error else {
                    Issue.record("Expected mutationCoordinationFailed, got \(error).")
                    return
                }
                #expect(error.errorDescription?.contains(lockFile.path(percentEncoded: false)) == true)
            }
        }
    }

    @Test("Reentrant mutation fails instead of waiting for its own lease")
    func reentrantMutation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let lockFile = directory.appending(path: "mutation.lock")
            let outerGate = MutationGate(lockFile: lockFile)
            let innerGate = MutationGate(lockFile: lockFile)

            let outcome = await withTaskGroup(of: ReentrantMutationOutcome.self) { group in
                group.addTask {
                    do {
                        try await outerGate.withAccess {
                            try await innerGate.withAccess { }
                        }
                        return .completed
                    } catch let error as SwiftlyKitError {
                        guard case .mutationCoordinationFailed = error,
                              error.errorDescription?.contains("reentrant") == true
                        else { return .otherFailure }
                        return .coordinationFailure
                    } catch {
                        return .otherFailure
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(200))
                    return .timedOut
                }

                let outcome = await group.next() ?? .otherFailure
                group.cancelAll()
                return outcome
            }

            #expect(outcome == .coordinationFailure)
        }
    }

    @Test("Inherited mutation context expires with the outer lease")
    func inheritedContextExpires() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let lockFile = directory.appending(path: "mutation.lock")
            let outerGate = MutationGate(lockFile: lockFile)
            let innerGate = MutationGate(lockFile: lockFile)
            let release = AsyncStream<Void>.makeStream()

            let inheritedTask = try await outerGate.withAccess {
                Task {
                    for await _ in release.stream { break }
                    try await innerGate.withAccess { }
                }
            }

            release.continuation.yield()
            try await inheritedTask.value
        }
    }

    @Test("An existing mutation lock is restricted to the current user")
    func existingLockPermissions() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let lockFile = directory.appending(path: "mutation.lock")
            try Data().write(to: lockFile)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o666],
                ofItemAtPath: lockFile.path(percentEncoded: false)
            )

            try await MutationGate(lockFile: lockFile).withAccess { }

            let attributes = try FileManager.default.attributesOfItem(atPath: lockFile.path(percentEncoded: false))
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o600)
        }
    }

    @Test("A spawned child does not retain the mutation lease")
    func childDescriptorInheritance() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let lockFile = directory.appending(path: "mutation.lock")
            let gate = MutationGate(lockFile: lockFile)
            let child = try await gate.withAccess { try spawnSleepingProcess() }
            defer { terminateAndWait(for: child) }

            let tracker = EntryTracker()
            let waiter = Task {
                try await MutationGate(lockFile: lockFile).withAccess { await tracker.enter() }
            }
            try await Task.sleep(for: .milliseconds(100))

            #expect(await tracker.didEnter)
            try await waiter.value
        }
    }

    @Test("Mutating operations never overlap")
    func serializesOperations() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let gate = MutationGate(lockFile: directory.appending(path: "mutation.lock"))
            let tracker = ConcurrencyTracker()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        try await gate.withAccess {
                            await tracker.enter()
                            try await Task.sleep(for: .milliseconds(2))
                            await tracker.leave()
                        }
                    }
                }
                try await group.waitForAll()
            }
            #expect(await tracker.maximum == 1)
        }
    }

    @Test("A cancelled waiter does not acquire or strand the gate")
    func cancellation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-MutationGate") { directory in
            let gate = MutationGate(lockFile: directory.appending(path: "mutation.lock"))
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let holder = Task {
                try await gate.withAccess {
                    entered.continuation.yield()
                    for await _ in release.stream { break }
                }
            }
            for await _ in entered.stream { break }

            let cancelledWaiter = Task {
                try await gate.withAccess { Issue.record("A cancelled waiter must not acquire the gate.") }
            }
            await Task.yield()
            cancelledWaiter.cancel()
            await #expect(throws: CancellationError.self) {
                try await cancelledWaiter.value
            }

            release.continuation.yield()
            try await holder.value
            try await gate.withAccess { }
        }
    }

}

private actor EntryTracker {

    private(set) var didEnter = false

    func enter() {
        didEnter = true
    }

}

private enum ReentrantMutationOutcome: Sendable {
    case coordinationFailure
    case completed
    case otherFailure
    case timedOut
}

private final class SiblingLockHolder: @unchecked Sendable {

    private let process: Process

    init(lockFile: URL, readyFile: URL) throws {

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, os, sys, time
            descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            os.close(os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
            time.sleep(30)
            """,
            lockFile.path(percentEncoded: false),
            readyFile.path(percentEncoded: false)
        ]
        try process.run()
        self.process = process
    }

    func terminate() {

        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

}

private final class PublicMutationFixture: @unchecked Sendable {

    private let process: Process

    var isRunning: Bool { process.isRunning }

    init(invalidPackage: URL, startedFile: URL, outcomeFile: URL) throws {

        let executable = coordinationPackageRoot()
            .appending(path: ".build/debug/SwiftlyKitCoordinationFixture")
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            invalidPackage.path(percentEncoded: false),
            startedFile.path(percentEncoded: false),
            outcomeFile.path(percentEncoded: false)
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    func waitUntilExit() async throws {

        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!process.isRunning)
    }

    func terminate() {

        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

}

private func waitForFile(_ file: URL) async throws {

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))

    while !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }

    try #require(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
}

private func coordinationPackageRoot() -> URL {

    var candidate = URL(filePath: #filePath).deletingLastPathComponent()
    while candidate.path(percentEncoded: false) != "/" {
        if FileManager.default.fileExists(atPath: candidate.appending(path: "Package.swift").path(percentEncoded: false)) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    return URL(filePath: "/")
}

private func spawnSleepingProcess() throws -> pid_t {

    var process = pid_t()
    var arguments = [strdup("/bin/sleep"), strdup("3"), nil]
    var actions: posix_spawn_file_actions_t?
    defer {
        posix_spawn_file_actions_destroy(&actions)
        arguments.compactMap { $0 }.forEach { free($0) }
    }

    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    let result = posix_spawn(&process, arguments[0], &actions, nil, &arguments, environ)
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    return process
}

private func terminateAndWait(for process: pid_t) {

    guard process > 0 else { return }
    kill(process, SIGKILL)
    waitpid(process, nil, 0)
}

private actor ConcurrencyTracker {

    private(set) var maximum = 0
    private var current = 0

    func enter() {
        current += 1
        maximum = max(maximum, current)
    }

    func leave() {
        current -= 1
    }

}
