import Darwin
import Foundation
import CryptoKit

/// Reader/writer admission for installed tools and exclusive admission for individual package resources.
actor MutationGate {

    /// Lock that excludes other Triple processes after local admission.
    private let processLock: ProcessMutationLock

    private var activeAccess: Access?
    private var occupants = 0

    /// Local callers that wait in FIFO order.
    private var waiters: [Waiter] = []

    /// Waiter IDs canceled before waiter registration completes.
    private var cancelledWaiters: Set<UUID> = []

    /// Waiter IDs granted while cancellation can still arrive.
    private var grantedWaiters: Set<UUID> = []

    /// Waiter IDs that cancellation can still affect.
    private var registeredWaiters: Set<UUID> = []

    init(lockFile: URL = ProcessMutationLock.defaultFile) {
        processLock = ProcessMutationLock(file: lockFile)
    }

    /// Waits for local and process admission, rejects reentry from the current task context, and runs the operation.
    /// Throws `CancellationError` if the task is canceled while it waits.
    func withAccess<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async throws -> Result {

        try await withAccess(.exclusive, operation: operation)
    }

    /// Protects installed tools from removal while allowing concurrent use of them.
    func withReadAccess<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async throws -> Result {

        try await withAccess(.shared, operation: operation)
    }

    private func withAccess<Result: Sendable>(
        _ access: Access,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {

        for lease in MutationLeaseContext.leases {
            guard !(await lease.isActive(for: processLock.identity)) else {
                throw TripleError.mutationCoordinationFailed(
                    "A reentrant Triple mutation cannot acquire its active coordination lease."
                )
            }
        }

        try await acquire(access)
        defer { release() }
        return try await processLock.withAccess(shared: access == .shared) {
            let lease = MutationLease(identity: processLock.identity)

            do {
                let result = try await MutationLeaseContext.$leases.withValue(
                    MutationLeaseContext.leases + [lease]
                ) {
                    try await operation()
                }
                await lease.invalidate()
                return result
            } catch {
                await lease.invalidate()
                throw error
            }
        }
    }

}

extension MutationGate {

    /// Gets local admission or waits in FIFO order until admission or cancellation.
    private func acquire(_ access: Access) async throws {

        try Task.checkCancellation()

        if occupants == 0 || access == .shared && activeAccess == .shared && waiters.isEmpty {
            activeAccess = access
            occupants += 1
            return
        }

        let id = UUID()
        registeredWaiters.insert(id)

        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledWaiters.remove(id) != nil {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, access: access, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }

        registeredWaiters.remove(id)
        cancelledWaiters.remove(id)
        grantedWaiters.remove(id)

        guard acquired else { throw CancellationError() }

        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Cancels a registered waiter. Does not resume the waiter after admission was granted.
    private func cancel(_ id: UUID) {

        guard registeredWaiters.contains(id) else { return }
        if grantedWaiters.remove(id) != nil { return }
        
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            cancelledWaiters.insert(id)
            return
        }

        let waiter = waiters.remove(at: index)

        waiter.continuation.resume(returning: false)
    }

    /// Gives admission to the first waiter not canceled. Makes the gate idle if no waiter remains.
    private func release() {

        occupants -= 1
        guard occupants == 0 else { return }
        activeAccess = nil

        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()

            if cancelledWaiters.remove(waiter.id) != nil {
                waiter.continuation.resume(returning: false)
                continue
            }

            grantedWaiters.insert(waiter.id)
            activeAccess = waiter.access
            occupants = 1
            waiter.continuation.resume(returning: true)

            if waiter.access == .shared {
                while waiters.first?.access == .shared {
                    let reader = waiters.removeFirst()
                    grantedWaiters.insert(reader.id)
                    occupants += 1
                    reader.continuation.resume(returning: true)
                }
            }
            
            return
        }

    }

}

/// File lock that excludes other Triple processes for one operation.
private struct ProcessMutationLock: Sendable {

    /// File used for cross-process coordination.
    let file: URL

    /// Identity used to detect reentry in a task context.
    let identity: MutationLockIdentity

    init(file: URL) {
        self.file = file
        self.identity = MutationLockIdentity(file: file)
    }

    /// Locks the file for the operation. Always unlocks and closes the file descriptor.
    func withAccess<Result: Sendable>(
        shared: Bool,
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {

        let descriptor = try await acquire(shared: shared)
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try await operation()
    }

}

extension ProcessMutationLock {

    /// Opens the user-only file without following a final symlink and waits for an exclusive lock.
    /// The wait supports cancellation, and child processes do not inherit the file descriptor.
    private func acquire(shared: Bool) async throws -> CInt {

        do { try prepareDirectory() }
        catch {
            throw TripleError.mutationCoordinationFailed(
                "Could not prepare \(file.path(percentEncoded: false)): \(error.localizedDescription)"
            )
        }

        let descriptor = open(file.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw coordinationFailure(errno) }

        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            close(descriptor)
            throw coordinationFailure(code, action: "secure")
        }

        do {
            while true {
                try Task.checkCancellation()

                if flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 {
                    try Task.checkCancellation()
                    return descriptor
                }

                let code = errno
                if code == EINTR { continue }
                guard code == EWOULDBLOCK || code == EAGAIN else { throw coordinationFailure(code) }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Creates the coordination directory for the current user if it does not exist.
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Converts a POSIX error to a Triple coordination error.
    private func coordinationFailure(_ code: CInt, action: String = "lock") -> TripleError {
        let description = String(cString: strerror(code))
        return .mutationCoordinationFailed("Could not \(action) \(file.path(percentEncoded: false)): \(description)")
    }

}

/// File-path identity used to detect reentry in a task context.
private struct MutationLockIdentity: Sendable, Equatable {

    /// Standardized path used for equality checks.
    let path: String

    init(file: URL) {
        path = file.standardizedFileURL.path(percentEncoded: false)
    }

}

extension ProcessMutationLock {

    /// Protocol-v1 file shared with existing SwiftlyKit processes for the current user.
    /// The legacy namespace preserves coordination with clients installed before the Triple rename.
    static let defaultFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SwiftlyKit/Coordination/v1", directoryHint: .isDirectory)
        .appending(path: "mutation.lock", directoryHint: .notDirectory)

}

/// Task-local storage for active mutation leases.
private enum MutationLeaseContext {

    /// Active leases inherited by child tasks.
    @TaskLocal static var leases: [MutationLease] = []

}

/// Revocable marker for one held process lock.
private actor MutationLease {

    /// Identity of the held process lock.
    private let lockIdentity: MutationLockIdentity

    /// True until the outer mutation ends.
    private var isActive = true

    init(identity: MutationLockIdentity) {
        self.lockIdentity = identity
    }

    /// Returns true if this lease is active for the specified lock.
    func isActive(for identity: MutationLockIdentity) -> Bool {
        isActive && lockIdentity == identity
    }

    /// Marks the lease as inactive before the process lock is released.
    func invalidate() {
        isActive = false
    }

}

extension MutationGate {

    /// Local request that waits for admission or cancellation.
    private struct Waiter {

        /// ID used to coordinate cancellation.
        let id: UUID
        let access: Access

        /// Returns true for admission and false for cancellation.
        let continuation: CheckedContinuation<Bool, Never>

    }

    private enum Access {
        case shared
        case exclusive
    }
    
}

extension MutationGate {

    /// Gate used by default Triple values and static workflows.
    static let shared = MutationGate()

}

extension MutationGate {

    /// Installed-only preparation cannot mutate tools; authorized installations require exclusive access.
    func withPreparationAccess<Result: Sendable>(
        _ assessment: EnvironmentAssessment,
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {

        if assessment.requiresInstallation {
            return try await withAccess(operation)
        }
        return try await withReadAccess(operation)
    }

    /// Protects installed tools and every affected directory, including overlapping scratch and export paths.
    func withPackageAccess<Result: Sendable>(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage,
        output: BuildOutput = .buildStorage,
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {

        let scratch = try scratchDirectory(using: environment, storage: scratchStorage)
        var directories = [environment.packageRoot, scratch.url]
        if case .export(let destination, _, _) = output { directories.append(destination) }
        let claims = try pathClaims(for: directories)
        return try await withReadAccess {
            try await self.withPathAccess(claims, operation: operation)
        }
    }

    /// Root configuration uses its own scratch directory and can overlap a package build.
    func withConfigurationAccess<Result: Sendable>(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage,
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {

        let scratch = try scratchDirectory(using: environment, storage: scratchStorage)
        let claims = try pathClaims(for: [scratch.url])
        return try await withReadAccess {
            try await self.withPathAccess(claims, operation: operation)
        }
    }

    /// Merges exclusive directories and shared ancestors, then orders all claims before acquisition.
    private func pathClaims(for directories: [URL]) throws -> [PathClaim] {

        var claims: [String: Access] = [:]
        for directory in directories {
            let canonical: URL
            do { canonical = try CanonicalFileURL.resolve(directory) }
            catch { throw TripleError.mutationCoordinationFailed("Could not identify a coordination directory.") }
            let path = Self.pathIdentity(canonical)
            claims[path] = .exclusive
            var ancestor = canonical.deletingLastPathComponent()
            while true {
                let parent = Self.pathIdentity(ancestor)
                if claims[parent] == nil { claims[parent] = .shared }
                if parent == "/" { break }
                ancestor.deleteLastPathComponent()
            }
        }
        let exclusive = claims.filter { $0.value == .exclusive }.map(\.key)
        return claims.keys.sorted().compactMap { path in
            guard !exclusive.contains(where: { ancestor in
                ancestor != path && (ancestor == "/" || path.hasPrefix(ancestor + "/"))
            }) else { return nil }
            return PathClaim(path: path, access: claims[path]!)
        }
    }

    /// Conservative case folding also excludes case and Unicode aliases on default macOS volumes.
    private static func pathIdentity(_ url: URL) -> String {

        var path = url.path(percentEncoded: false)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// One namespace makes parent resets exclude nested scratches and exports across resource kinds.
    private func withPathAccess<Result: Sendable>(
        _ claims: [PathClaim],
        index: Int = 0,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {

        guard index < claims.count else { return try await operation() }
        let claim = claims[index]
        let digest = SHA256.hash(data: Data(claim.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let gate = MutationGate(lockFile: processLock.file.deletingLastPathComponent()
            .appending(path: "path-\(digest).lock"))
        return try await gate.withAccess(claim.access) {
            try await self.withPathAccess(claims, index: index + 1, operation: operation)
        }
    }

    private struct PathClaim: Sendable {
        let path: String
        let access: Access
    }

    private func scratchDirectory(
        using environment: LocalBuildEnvironment,
        storage: SwiftPMScratchStorage
    ) throws -> SwiftPMScratchDirectory {

        do {
            return try SwiftPMScratchDirectory(
                storage: storage,
                packageRoot: environment.packageRoot,
                sharedStorage: environment.swiftPMSharedStorage,
                environmentStorage: environment.environmentStorage
            )
        } catch let error {
            throw error.tripleError
        }
    }

}
