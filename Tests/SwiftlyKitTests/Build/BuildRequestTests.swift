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
        #expect(request.storage == .packageDefault)
        #expect(request.output == .buildStorage)
        #expect(request.strip == false)
    }

    @Test("Copied output retains build storage by default")
    func copiedOutputDefault() {

        let destination = URL(filePath: "/tmp/Server")
        let output = BuildOutput.copy(to: destination)

        #expect(output == .copy(to: destination, replacingExisting: false, cleanup: .retain))
    }

    @Test("Copied output retains an explicit replacement choice")
    func copiedOutputReplacement() {

        let destination = URL(filePath: "/tmp/Server")
        let output = BuildOutput.copy(to: destination, replacingExisting: true)

        #expect(output == .copy(to: destination, replacingExisting: true, cleanup: .retain))
    }

}
