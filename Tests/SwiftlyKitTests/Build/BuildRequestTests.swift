import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Build request")
struct BuildRequestTests {

    @Test("Requests provide the documented defaults")
    func defaults() {

        let request = BuildRequest(
            ExecutableProduct(name: "Server")
        )

        #expect(request.configuration == .release)
        #expect(request.jobs == nil)
        #expect(request.scratchStorage == .packageDefault)
        #expect(request.output == .buildStorage)
        #expect(request.strip == false)
    }

    @Test("Published output retains build storage by default")
    func publishedOutputDefault() {

        let destination = URL(filePath: "/tmp/Server")
        let output = BuildOutput.publish(to: destination)

        #expect(output == .publish(to: destination, replacingExisting: false, cleanup: .retain))
    }

}
