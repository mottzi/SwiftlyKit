import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Atomic build output publication")
struct AtomicOutputPublisherTests {

    @Test("Publishes bytes and refuses replacement")
    func publishNoReplace() throws {

        try withSwiftPMTemporaryDirectory { directory in
            let source = directory.appending(path: "source")
            let output = directory.appending(path: "output")
            try Data("first".utf8).write(to: source)
            #expect(try AtomicOutputPublisher.publish(source, to: output) == output)
            #expect(try Data(contentsOf: output) == Data("first".utf8))

            try Data("second".utf8).write(to: source)
            #expect(throws: SwiftPMError.outputAlreadyExists(output)) {
                try AtomicOutputPublisher.publish(source, to: output)
            }
            #expect(try Data(contentsOf: output) == Data("first".utf8))
        }
    }

    @Test("Concurrent publishers cannot replace the winning output")
    func concurrentPublication() async throws {

        try await withSwiftPMTemporaryDirectory { directory in
            let first = directory.appending(path: "first")
            let second = directory.appending(path: "second")
            let output = directory.appending(path: "output")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)

            let attempts = await withTaskGroup(of: PublicationAttempt.self) { group in
                for source in [first, second] {
                    group.addTask {
                        do { return .published(try AtomicOutputPublisher.publish(source, to: output)) }
                        catch let error as SwiftPMError { return .rejected(error) }
                        catch { return .unexpected }
                    }
                }

                var attempts: [PublicationAttempt] = []
                for await attempt in group { attempts.append(attempt) }
                return attempts
            }

            #expect(attempts.filter(\.wasPublished).count == 1)
            #expect(attempts.filter(\.wasRejectedAsExisting).count == 1)
            let bytes = try Data(contentsOf: output)
            #expect(bytes == Data("first".utf8) || bytes == Data("second".utf8))
        }
    }

}

private enum PublicationAttempt: Sendable {
    case published(URL)
    case rejected(SwiftPMError)
    case unexpected

    var wasPublished: Bool {
        if case .published = self { return true }
        return false
    }

    var wasRejectedAsExisting: Bool {
        if case .rejected(.outputAlreadyExists) = self { return true }
        return false
    }
}
