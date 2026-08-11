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
        #expect(request.scratchDirectory == nil)
        #expect(request.output == nil)
        #expect(request.strip == false)
        #expect(request.environment.isEmpty)
    }

}
