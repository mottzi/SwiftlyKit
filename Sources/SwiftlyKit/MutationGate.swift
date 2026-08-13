import Foundation

/// A cancellation-aware FIFO gate shared by public mutating workflows in one process.
actor MutationGate {

    static let shared = MutationGate()
    
    private var isOccupied = false
    private var waiters: [Waiter] = []
    private var cancelledWaiters: Set<UUID> = []
    private var grantedWaiters: Set<UUID> = []
    
    func withAccess<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        
        try await acquire()
        defer { release() }
        return try await operation()
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

        grantedWaiters.remove(id)

        guard acquired else { throw CancellationError() }

        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancel(_ id: UUID) {

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

extension MutationGate {
    
    private struct Waiter {

        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>

    }
    
}
