import Darwin
import Foundation

/// A cancellation-aware local FIFO gate with an exclusive lease across cooperating processes.
actor MutationGate {

    static let shared = MutationGate()

    private let processLock: ProcessMutationLock
    private var isOccupied = false
    private var waiters: [Waiter] = []
    private var cancelledWaiters: Set<UUID> = []
    private var grantedWaiters: Set<UUID> = []
    private var registeredWaiters: Set<UUID> = []

    init(lockFile: URL = ProcessMutationLock.defaultFile) {
        processLock = ProcessMutationLock(file: lockFile)
    }

    /// Runs one mutation after local FIFO admission and exclusive cross-process lease acquisition.
    func withAccess<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {

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
            let lease = MutationLease(lockFile: processLock.identity)

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

/// A persistent advisory file lock for one user-scoped mutation lease.
private struct ProcessMutationLock: Sendable {

    let file: URL

    /// Returns the path identity used for task-local reentrancy detection.
    var identity: String { file.standardizedFileURL.path }

    /// Runs one mutation while this process owns the persistent advisory lock.
    func withAccess<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {

        let descriptor = try await acquire()
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try await operation()
    }

}

extension ProcessMutationLock {

    private func acquire() async throws -> CInt {

        do { try prepareDirectory() }
        catch {
            throw SwiftlyKitError.mutationCoordinationFailed(
                "Could not prepare \(file.path): \(error.localizedDescription)"
            )
        }

        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw coordinationFailure(errno) }

        if fchmod(descriptor, S_IRUSR | S_IWUSR) != 0 {
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

                if errno == EINTR { continue }
                guard errno == EWOULDBLOCK else { throw coordinationFailure(errno) }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func coordinationFailure(_ code: CInt, action: String = "lock") -> SwiftlyKitError {
        let description = String(cString: strerror(code))
        return .mutationCoordinationFailed("Could not \(action) \(file.path): \(description)")
    }

}

extension ProcessMutationLock {

    static let defaultFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SwiftlyKit/Coordination/v1", directoryHint: .isDirectory)
        .appending(path: "mutation.lock", directoryHint: .notDirectory)

}

/// Task-local leases that reject nested acquisition while their outer mutation remains active.
private enum MutationLeaseContext {

    @TaskLocal static var leases: [MutationLease] = []

}

/// Shared lease state inherited by unstructured child tasks.
private actor MutationLease {

    private let lockFile: String
    private var isActive = true

    init(lockFile: String) {
        self.lockFile = lockFile
    }

    /// Returns whether this lease still owns the selected lock file.
    func isActive(for lockFile: String) -> Bool {
        isActive && self.lockFile == lockFile
    }

    /// Marks this lease inactive before the process lock is released.
    func invalidate() {
        isActive = false
    }

}

extension MutationGate {

    private struct Waiter {

        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>

    }
    
}
