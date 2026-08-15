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

        #expect(request.configuration == .debug)
        #expect(request.jobs == nil)
        #expect(request.storage == .packageDefault)
        #expect(request.output == .buildStorage)
        #expect(request.strip == false)
    }

    @Test("Requests retain an explicit concurrent build job limit")
    func jobs() {

        let request = BuildRequest(
            ExecutableProduct(name: "Server"),
            jobs: 4
        )

        #expect(request.jobs == 4)
    }

    @Test("Published output retains build storage by default")
    func publishedOutputDefault() {

        let destination = URL(filePath: "/tmp/Server")
        let output = BuildOutput.publish(to: destination)

        #expect(output == .publish(to: destination, replacingExisting: false, cleanup: .retain))
    }

    @Test("Published output retains an explicit replacement choice")
    func publishedOutputReplacement() {

        let destination = URL(filePath: "/tmp/Server")
        let output = BuildOutput.publish(to: destination, replacingExisting: true)

        #expect(output == .publish(to: destination, replacingExisting: true, cleanup: .retain))
    }

    @Test("Published output retains an explicit cleanup choice")
    func publishedOutputCleanup() {

        let destination = URL(filePath: "/tmp/PublishedServer")
        let output = BuildOutput.publish(to: destination, cleanup: .reset)

        #expect(output == .publish(to: destination, replacingExisting: false, cleanup: .reset))
    }

}
