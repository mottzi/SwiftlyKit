import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Build runtime package description")
struct PackageDescriptionTests {
    @Test("Discovers explicit and implicit executable products in stable order")
    func discoversExecutables() throws {
        let description = try BuildRuntimePackageDescription(data: Data(json.utf8))
        #expect(description.products.map(\.name) == ["Explicit", "Implicit"])
        #expect(description.requiresResources("Explicit"))
        #expect(!description.requiresResources("Implicit"))
    }

    private var json: String {
        """
        {
          "products": [
            {"name":"Library","targets":["Library"],"type":{"library":["automatic"]}},
            {"name":"Explicit","targets":["Main"],"type":{"executable":null}}
          ],
          "targets": [
            {"name":"Main","type":"executable","dependencies":[{"target":["Resources",null]}],"resources":[]},
            {"name":"Resources","type":"regular","dependencies":[],"resources":[{"rule":{"process":{}},"path":"asset.txt"}]},
            {"name":"Implicit","type":"executable","dependencies":[],"resources":[]},
            {"name":"Library","type":"regular","dependencies":[],"resources":[]}
          ]
        }
        """
    }
}
