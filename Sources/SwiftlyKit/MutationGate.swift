import Darwin
import Foundation

/// Mutation gate for one user. It queues local operations and excludes other SwiftlyKit processes.
actor MutationGate {

    /// Gate used by default SwiftlyKit values and static workflows.
    static let shared = MutationGate()

    /// Lock that excludes other SwiftlyKit processes after local admission.
    private let processLock: ProcessMutationLock

    /// True if a local operation has admission.
    private var isOccupied = false

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

        for lease in MutationLeaseContext.leases {
            guard !(await lease.isActive(for: processLock.identity)) else {
                throw SwiftlyKitError.mutationCoordinationFailed(
                    "A reentrant SwiftlyKit mutation cannot acquire its active coordination lease."
                )
            }
        }

        try await acquire()
        defer { release() }
        return try await processLock.withAccess {
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
    private func acquire() async throws {

        try Task.checkCancellation()

        guard isOccupied else {
            isOccupied = true
            return
        }

        let id = UUID()
        registeredWaiters.insert(id)

        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledWaiters.remove(id) != nil {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
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

        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()

            if cancelledWaiters.remove(waiter.id) != nil {
                waiter.continuation.resume(returning: false)
                continue
            }

            grantedWaiters.insert(waiter.id)
            waiter.continuation.resume(returning: true)
            
            return
        }

        isOccupied = false
    }

}

/// File lock that excludes other SwiftlyKit processes for one operation.
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
    func withAccess<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async throws -> Result {

        let descriptor = try await acquire()
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
    private func acquire() async throws -> CInt {

        do { try prepareDirectory() }
        catch {
            throw SwiftlyKitError.mutationCoordinationFailed(
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

                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
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

    /// Converts a POSIX error to a SwiftlyKit coordination error.
    private func coordinationFailure(_ code: CInt, action: String = "lock") -> SwiftlyKitError {
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

    /// Protocol-v1 file used by cooperating SwiftlyKit processes for the current user.
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

        /// Returns true for admission and false for cancellation.
        let continuation: CheckedContinuation<Bool, Never>

    }
    
}
