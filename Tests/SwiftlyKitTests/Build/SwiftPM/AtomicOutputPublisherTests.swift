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
}
