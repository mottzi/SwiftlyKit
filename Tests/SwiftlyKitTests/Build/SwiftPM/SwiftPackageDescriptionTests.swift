import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Swift package description")
struct SwiftPackageDescriptionTests {

    @Test("Discovers named explicit and implicit executable products in stable order")
    func discoversExecutables() throws {

        let description = try SwiftPackageDescription(data: Data(json.utf8))
        #expect(description.products.map(\.name) == ["Explicit", "Implicit"])
        #expect(description.requiresRuntimeResources("Explicit"))
        #expect(!description.requiresRuntimeResources("Implicit"))
    }

    @Test("Only external and unknown resource rules require runtime bundles")
    func classifiesResourceRules() throws {

        let cases: [(rules: String, expected: Bool)] = [
            ("", false),
            (#"{"rule":{"embedInCode":{}},"path":"embedded.txt"}"#, false),
            (#"{"rule":{"copy":{}},"path":"copied.txt"}"#, true),
            (#"{"rule":{"process":{}},"path":"processed.txt"}"#, true),
            (#"{"rule":{"future":{}},"path":"unknown.txt"}"#, true),
            (#"{"rule":{"embedInCode":{}},"path":"embedded.txt"},{"rule":{"copy":{}},"path":"copied.txt"}"#, true)
        ]

        for testCase in cases {
            let data = Data(packageJSON(resources: testCase.rules).utf8)
            let description = try SwiftPackageDescription(data: data)
            #expect(description.requiresRuntimeResources("Tool") == testCase.expected)
        }
    }

    private var json: String {
        """
        {
          "products": [
            {"name":"Library","targets":["Library"],"type":{"library":["automatic"]}},
            {"name":"","targets":["Main"],"type":{"executable":null}},
            {"name":"Explicit","targets":["Main"],"type":{"executable":null}}
          ],
          "targets": [
            {"name":"","type":"executable","dependencies":[],"resources":[]},
            {"name":"Main","type":"executable","dependencies":[{"target":["Resources",null]}],"resources":[]},
            {"name":"Resources","type":"regular","dependencies":[],"resources":[{"rule":{"process":{}},"path":"asset.txt"}]},
            {"name":"Implicit","type":"executable","dependencies":[],"resources":[]},
            {"name":"Library","type":"regular","dependencies":[],"resources":[]}
          ]
        }
        """
    }

    private func packageJSON(resources: String) -> String {
        """
        {
          "products": [],
          "targets": [
            {
              "name": "Tool",
              "type": "executable",
              "dependencies": [],
              "resources": [\(resources)]
            }
          ]
        }
        """
    }

}
