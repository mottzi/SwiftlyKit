import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Swift package description")
struct PackageDescriptionTests {

    @Test("Discovers explicit and implicit executable products in stable order")
    func discoversExecutables() throws {

        let description = try description(
            products: """
            {"name":"Library","targets":["Library"],"type":{"library":["automatic"]}},
            {"name":"Explicit","targets":["Main"],"type":{"executable":null}}
            """,
            targets: """
            {"name":"Main","type":"executable"},
            {"name":"Implicit","type":"executable"},
            {"name":"Library","type":"regular"}
            """
        )

        #expect(description.products.map(\.name) == ["Explicit", "Implicit"])
    }

    @Test("Invalid JSON and missing or mistyped top-level arrays are malformed")
    func rejectsMalformedTopLevelDescription() {

        #expect(throws: SwiftPMError.malformedPackageDescription) {
            try PackageDescription(data: Data([0xff]))
        }

        let malformedDescriptions = [
            "null",
            "[]",
            "{}",
            #"{"products":[]}"#,
            #"{"targets":[]}"#,
            #"{"products":{},"targets":[]}"#,
            #"{"products":[],"targets":{}}"#,
            #"{"products":null,"targets":[]}"#,
            #"{"products":[],"targets":null}"#
        ]

        for json in malformedDescriptions {
            #expect(throws: SwiftPMError.malformedPackageDescription) {
                try PackageDescription(data: Data(json.utf8))
            }
        }
    }

    @Test("Malformed product entries and required fields are rejected")
    func rejectsMalformedProducts() {

        let malformedProducts = [
            "42",
            #"{"targets":["Tool"],"type":{"executable":null}}"#,
            #"{"name":42,"targets":["Tool"],"type":{"executable":null}}"#,
            #"{"name":"","targets":["Tool"],"type":{"executable":null}}"#,
            #"{"name":"Tool","type":{"executable":null}}"#,
            #"{"name":"Tool","targets":[],"type":{"executable":null}}"#,
            #"{"name":"Tool","targets":"Tool","type":{"executable":null}}"#,
            #"{"name":"Tool","targets":[42],"type":{"executable":null}}"#,
            #"{"name":"Tool","targets":["Tool","Tool"],"type":{"executable":null}}"#,
            #"{"name":"Tool","targets":["Missing"],"type":{"executable":null}}"#,
            #"{"name":"Tool","targets":["Tool"]}"#,
            #"{"name":"Tool","targets":["Tool"],"type":"executable"}"#,
            #"{"name":"Tool","targets":["Tool"],"type":{}}"#,
            #"{"name":"Tool","targets":["Tool"],"type":{"executable":null,"library":["automatic"]}}"#,
            #"{"name":"Tool","targets":["Tool"],"type":{"executable":[]}}"#,
            #"{"name":"Tool","targets":["Tool"],"type":{"library":[]}}"#,
            #"{"name":"Tool","targets":["Tool"],"type":{"library":["automatic","dynamic"]}}"#,
            #"{"name":"Tool","targets":["Tool"],"type":{"library":[""]}}"#,
            #"{"name":"Tool","targets":["Tool"],"type":{"library":[42]}}"#
        ]

        for product in malformedProducts {
            let json = packageJSON(products: product, targets: regularTarget(name: "Tool"))
            #expect(throws: SwiftPMError.malformedPackageDescription) {
                try PackageDescription(data: Data(json.utf8))
            }
        }
    }

    @Test("Malformed target entries and required fields are rejected")
    func rejectsMalformedTargets() {

        let malformedTargets = [
            "42",
            #"{"type":"executable"}"#,
            #"{"name":42,"type":"executable"}"#,
            #"{"name":"","type":"executable"}"#,
            #"{"name":"Tool"}"#,
            #"{"name":"Tool","type":42}"#,
            #"{"name":"Tool","type":""}"#
        ]

        for target in malformedTargets {
            let json = packageJSON(
                products: executableProduct(name: "Tool", targets: ["Tool"]),
                targets: target
            )
            #expect(throws: SwiftPMError.malformedPackageDescription) {
                try PackageDescription(data: Data(json.utf8))
            }
        }
    }

    @Test("Duplicate product and target names are malformed")
    func rejectsDuplicateNames() {

        let duplicateProducts = packageJSON(
            products: """
            \(executableProduct(name: "Tool", targets: ["Tool"])),
            \(executableProduct(name: "Tool", targets: ["Tool"]))
            """,
            targets: regularTarget(name: "Tool")
        )
        #expect(throws: SwiftPMError.malformedPackageDescription) {
            try PackageDescription(data: Data(duplicateProducts.utf8))
        }

        let duplicateTargets = packageJSON(
            products: executableProduct(name: "Tool", targets: ["Tool"]),
            targets: """
            \(regularTarget(name: "Tool")),
            \(regularTarget(name: "Tool"))
            """
        )
        #expect(throws: SwiftPMError.malformedPackageDescription) {
            try PackageDescription(data: Data(duplicateTargets.utf8))
        }
    }

    @Test("Dependency and resource payloads are outside product discovery")
    func ignoresUnneededTargetPayloads() throws {

        let json = """
        {
          "futureRoot":{"enabled":true},
          "products":[
            {"name":"Tool","targets":["Tool"],"type":{"executable":null},"futureProduct":[1,2,3]}
          ],
          "targets":[
            {"name":"Tool","type":"executable","dependencies":42,"resources":false,"futureTarget":{"value":1}}
          ]
        }
        """
        let description = try PackageDescription(data: Data(json.utf8))

        #expect(description.products.map(\.name) == ["Tool"])
    }

    @Test("Unknown product and target kinds are not advertised")
    func ignoresUnknownKinds() throws {

        let description = try description(
            products: #"{"name":"FutureProduct","targets":["FutureTarget"],"type":{"future":null}}"#,
            targets: #"{"name":"FutureTarget","type":"future"}"#
        )

        #expect(description.products.isEmpty)
    }

    @Test("An explicit non-executable product suppresses an implicit executable with the same name")
    func explicitProductNameSuppressesImplicitExecutable() throws {

        let description = try description(
            products: #"{"name":"Tool","targets":["Library"],"type":{"library":["automatic"]}}"#,
            targets: """
            {"name":"Tool","type":"executable"},
            \(regularTarget(name: "Library"))
            """
        )

        #expect(description.products.isEmpty)
    }

    @Test("Encoded fixtures preserve unusual product names")
    func fixtureEscapesProductNames() throws {

        let name = "quote\" slash\\ newline\n snowman ☃️"
        let json = try packageDescriptionJSON(executableProducts: [name])
        let description = try PackageDescription(data: Data(json.utf8))

        #expect(description.products.map(\.name) == [name])
    }

}

extension PackageDescriptionTests {

    private func description(products: String, targets: String) throws -> PackageDescription {
        try PackageDescription(data: Data(packageJSON(products: products, targets: targets).utf8))
    }

    private func packageJSON(products: String, targets: String) -> String {
        """
        {
          "products": [\(products)],
          "targets": [\(targets)]
        }
        """
    }

    private func executableProduct(name: String, targets: [String]) -> String {
        let targets = targets.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"name":"\#(name)","targets":[\#(targets)],"type":{"executable":null}}"#
    }

    private func regularTarget(name: String) -> String {
        #"{"name":"\#(name)","type":"regular"}"#
    }

}
