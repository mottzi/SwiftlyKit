import Foundation
import Testing
@testable import Triple

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

    @Test("Exported output retains build storage by default")
    func exportedOutputDefault() {

        let destination = URL(filePath: "/tmp/Server")
        let output = BuildOutput.export(to: destination)

        #expect(output == .export(to: destination, policy: .createNewDirectory, cleanup: .retain))
    }

}
