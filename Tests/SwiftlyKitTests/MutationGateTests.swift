import Testing
@testable import SwiftlyKit

@Suite("Mutation gate")
struct MutationGateTests {

    @Test("Mutating operations never overlap")
    func serializesOperations() async throws {

        let gate = MutationGate()
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

    @Test("A cancelled waiter does not acquire or strand the gate")
    func cancellation() async throws {

        let gate = MutationGate()
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
