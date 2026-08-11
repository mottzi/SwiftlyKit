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
            {"name":"Main","type":"executable","dependencies":[{"target":["Resources",null]}],"resources":[]},
            {"name":"Resources","type":"regular","dependencies":[],"resources":[{"rule":{"process":{}},"path":"asset.txt"}]},
            {"name":"Implicit","type":"executable","dependencies":[],"resources":[]},
            {"name":"Library","type":"regular","dependencies":[],"resources":[]}
            """
        )

        #expect(description.products.map(\.name) == ["Explicit", "Implicit"])
        #expect(description.requiresRuntimeResources("Explicit"))
        #expect(!description.requiresRuntimeResources("Implicit"))
    }

    @Test("External product metadata never creates local target edges")
    func ignoresExternalProductMetadataCollisions() throws {

        let description = try description(
            products: executableProduct(name: "Tool", targets: ["Tool"]),
            targets: """
            {"name":"Tool","type":"executable","dependencies":[{"product":["ProductCollision","PackageCollision",null,{"platformNames":["PlatformCollision"],"config":"ConfigurationCollision","traits":["TraitCollision"]}]}],"resources":[]},
            \(resourceTarget(name: "ProductCollision")),
            \(resourceTarget(name: "PackageCollision")),
            \(resourceTarget(name: "PlatformCollision")),
            \(resourceTarget(name: "ConfigurationCollision")),
            \(resourceTarget(name: "TraitCollision"))
            """
        )

        #expect(!description.requiresRuntimeResources("Tool"))
    }

    @Test("Target and matching by-name dependencies create local edges")
    func followsLocalDependencyEdges() throws {

        let description = try description(
            products: """
            \(executableProduct(name: "Direct", targets: ["Direct"])),
            \(executableProduct(name: "ByName", targets: ["ByName"]))
            """,
            targets: """
            {"name":"Direct","type":"executable","dependencies":[{"target":["DirectResources",null]}],"resources":[]},
            {"name":"ByName","type":"executable","dependencies":[{"byName":["ByNameResources",null]}],"resources":[]},
            \(resourceTarget(name: "DirectResources")),
            \(resourceTarget(name: "ByNameResources"))
            """
        )

        #expect(description.requiresRuntimeResources("Direct"))
        #expect(description.requiresRuntimeResources("ByName"))
    }

    @Test("An unmatched by-name dependency is treated as external")
    func ignoresUnmatchedByNameDependency() throws {

        let description = try description(
            products: executableProduct(name: "Tool", targets: ["Tool"]),
            targets: """
            {"name":"Tool","type":"executable","dependencies":[{"byName":["ExternalOnly",null]}],"resources":[]}
            """
        )

        #expect(!description.requiresRuntimeResources("Tool"))
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
            #"{"type":"executable","dependencies":[],"resources":[]}"#,
            #"{"name":42,"type":"executable","dependencies":[],"resources":[]}"#,
            #"{"name":"","type":"executable","dependencies":[],"resources":[]}"#,
            #"{"name":"Tool","dependencies":[],"resources":[]}"#,
            #"{"name":"Tool","type":42,"dependencies":[],"resources":[]}"#,
            #"{"name":"Tool","type":"executable","resources":[]}"#,
            #"{"name":"Tool","type":"executable","dependencies":{},"resources":[]}"#,
            #"{"name":"Tool","type":"executable","dependencies":[42],"resources":[]}"#,
            #"{"name":"Tool","type":"executable","dependencies":[{"target":[]}],"resources":[]}"#,
            #"{"name":"Tool","type":"executable","dependencies":[{"target":["",null]}],"resources":[]}"#,
            #"{"name":"Tool","type":"executable","dependencies":[{"target":["Missing",null]}],"resources":[]}"#,
            #"{"name":"Tool","type":"executable","dependencies":[{"target":["Tool",null],"byName":["Tool",null]}],"resources":[]}"#,
            #"{"name":"Tool","type":"executable","dependencies":[]}"#,
            #"{"name":"Tool","type":"executable","dependencies":[],"resources":{}}"#
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

    @Test("Unknown extra fields are tolerated")
    func toleratesUnknownFields() throws {

        let json = """
        {
          "futureRoot":{"enabled":true},
          "products":[
            {"name":"Tool","targets":["Tool"],"type":{"executable":null},"futureProduct":[1,2,3]}
          ],
          "targets":[
            {"name":"Tool","type":"executable","dependencies":[],"resources":[{"rule":{"embedInCode":{}},"path":"asset.txt","futureResource":true}],"futureTarget":{"value":1}}
          ]
        }
        """
        let description = try PackageDescription(data: Data(json.utf8))

        #expect(description.products.map(\.name) == ["Tool"])
        #expect(!description.requiresRuntimeResources("Tool"))
    }

    @Test("Unknown product and target kinds are not advertised")
    func ignoresUnknownKinds() throws {

        let description = try description(
            products: #"{"name":"FutureProduct","targets":["FutureTarget"],"type":{"future":null}}"#,
            targets: #"{"name":"FutureTarget","type":"future","dependencies":[],"resources":[]}"#
        )

        #expect(description.products.isEmpty)
        #expect(!description.requiresRuntimeResources("FutureProduct"))
        #expect(!description.requiresRuntimeResources("FutureTarget"))
    }

    @Test("An explicit non-executable product suppresses an implicit executable with the same name")
    func explicitProductNameSuppressesImplicitExecutable() throws {

        let description = try description(
            products: #"{"name":"Tool","targets":["Library"],"type":{"library":["automatic"]}}"#,
            targets: """
            {"name":"Tool","type":"executable","dependencies":[],"resources":[]},
            \(regularTarget(name: "Library"))
            """
        )

        #expect(description.products.isEmpty)
        #expect(!description.requiresRuntimeResources("Tool"))
    }

    @Test("A reachable unknown dependency is conservative without tainting unrelated products")
    func handlesUnknownDependenciesConservatively() throws {

        let description = try description(
            products: """
            \(executableProduct(name: "Tainted", targets: ["Tainted"])),
            \(executableProduct(name: "Clean", targets: ["Clean"]))
            """,
            targets: """
            {"name":"Tainted","type":"executable","dependencies":[{"futureDependency":["Somewhere",null]}],"resources":[]},
            {"name":"Clean","type":"executable","dependencies":[],"resources":[]},
            {"name":"Unreachable","type":"regular","dependencies":[{"futureDependency":["Elsewhere",null]}],"resources":[]}
            """
        )

        #expect(description.requiresRuntimeResources("Tainted"))
        #expect(!description.requiresRuntimeResources("Clean"))
    }

    @Test("Dependency condition metadata never creates local edges")
    func ignoresDependencyConditionCollisions() throws {

        let description = try description(
            products: """
            \(executableProduct(name: "TargetTool", targets: ["TargetTool"])),
            \(executableProduct(name: "ByNameTool", targets: ["ByNameTool"]))
            """,
            targets: """
            {"name":"TargetTool","type":"executable","dependencies":[{"target":["DryLeaf",{"platformNames":["TargetConditionResources"],"config":"TargetConfigurationResources"}]}],"resources":[]},
            {"name":"ByNameTool","type":"executable","dependencies":[{"byName":["ExternalOnly",{"platformNames":["ByNameConditionResources"],"config":"ByNameConfigurationResources"}]}],"resources":[]},
            \(regularTarget(name: "DryLeaf")),
            \(resourceTarget(name: "TargetConditionResources")),
            \(resourceTarget(name: "TargetConfigurationResources")),
            \(resourceTarget(name: "ByNameConditionResources")),
            \(resourceTarget(name: "ByNameConfigurationResources"))
            """
        )

        #expect(!description.requiresRuntimeResources("TargetTool"))
        #expect(!description.requiresRuntimeResources("ByNameTool"))
    }

    @Test("An unreachable unknown resource rule does not taint an unrelated executable")
    func isolatesUnknownResourcesByReachability() throws {

        let description = try description(
            products: executableProduct(name: "Clean", targets: ["Clean"]),
            targets: """
            {"name":"Clean","type":"executable","dependencies":[],"resources":[]},
            {"name":"Unreachable","type":"regular","dependencies":[],"resources":[{"rule":{"future":{}},"path":"future.asset"}]}
            """
        )

        #expect(!description.requiresRuntimeResources("Clean"))
    }

    @Test("Dependency cycles terminate and still discover reachable resources")
    func handlesCycles() throws {

        let description = try description(
            products: """
            \(executableProduct(name: "DryCycle", targets: ["DryA"])),
            \(executableProduct(name: "ResourceCycle", targets: ["ResourceA"]))
            """,
            targets: """
            {"name":"DryA","type":"regular","dependencies":[{"target":["DryB",null]}],"resources":[]},
            {"name":"DryB","type":"regular","dependencies":[{"byName":["DryA",null]}],"resources":[]},
            {"name":"ResourceA","type":"regular","dependencies":[{"target":["ResourceB",null]}],"resources":[]},
            {"name":"ResourceB","type":"regular","dependencies":[{"target":["ResourceA",null]},{"byName":["Assets",null]}],"resources":[]},
            \(resourceTarget(name: "Assets"))
            """
        )

        #expect(!description.requiresRuntimeResources("DryCycle"))
        #expect(description.requiresRuntimeResources("ResourceCycle"))
    }

    @Test("Embed, copy, process, and unknown resource rules are classified conservatively")
    func classifiesResourceRules() throws {

        let cases: [(resources: String, expected: Bool)] = [
            ("", false),
            (#"{"rule":{"embedInCode":{}},"path":"embedded.txt"}"#, false),
            (#"{"rule":{"copy":{}},"path":"copied.txt"}"#, true),
            (#"{"rule":{"process":{}},"path":"processed.txt"}"#, true),
            (#"{"rule":{"process":{"localization":"default"}},"path":"localized.txt"}"#, true),
            (#"{"rule":{"future":{}},"path":"unknown.txt"}"#, true),
            (#"{"rule":{"embedInCode":{}},"path":"embedded.txt"},{"rule":{"process":{}},"path":"processed.txt"}"#, true)
        ]

        for testCase in cases {
            let description = try description(
                products: executableProduct(name: "Tool", targets: ["Tool"]),
                targets: """
                {"name":"Tool","type":"executable","dependencies":[],"resources":[\(testCase.resources)]}
                """
            )
            #expect(description.requiresRuntimeResources("Tool") == testCase.expected)
        }
    }

    @Test("Malformed resource entries and rules are rejected")
    func rejectsMalformedResources() {

        let malformedResources = [
            #"{"path":"missing-rule.txt"}"#,
            #"{"rule":"process","path":"wrong-rule-type.txt"}"#,
            #"{"rule":{"embedInCode":{},"copy":{}},"path":"ambiguous.txt"}"#,
            #"{"rule":{"embedInCode":{}}}"#,
            #"{"rule":{"embedInCode":{}},"path":""}"#,
            #"{"rule":{"copy":null},"path":"invalid-payload.txt"}"#,
            "17"
        ]

        for resource in malformedResources {
            let json = packageJSON(
                products: executableProduct(name: "Tool", targets: ["Tool"]),
                targets: """
                {"name":"Tool","type":"executable","dependencies":[],"resources":[\(resource)]}
                """
            )
            #expect(throws: SwiftPMError.malformedPackageDescription) {
                try PackageDescription(data: Data(json.utf8))
            }
        }
    }

    @Test("Encoded fixtures preserve unusual product names")
    func fixtureEscapesProductNames() throws {

        let name = "quote\" slash\\ newline\n snowman ☃\u{FE0F}"
        let json = try packageDescriptionJSON(executableProducts: [name])
        let description = try PackageDescription(data: Data(json.utf8))

        #expect(description.products.map(\.name) == [name])
        #expect(!description.requiresRuntimeResources(name))
    }

}

private extension PackageDescriptionTests {

    func description(products: String, targets: String) throws -> PackageDescription {
        try PackageDescription(data: Data(packageJSON(products: products, targets: targets).utf8))
    }

    func packageJSON(products: String, targets: String) -> String {
        """
        {
          "products": [\(products)],
          "targets": [\(targets)]
        }
        """
    }

    func executableProduct(name: String, targets: [String]) -> String {
        let targets = targets.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"name":"\#(name)","targets":[\#(targets)],"type":{"executable":null}}"#
    }

    func regularTarget(name: String) -> String {
        #"{"name":"\#(name)","type":"regular","dependencies":[],"resources":[]}"#
    }

    func resourceTarget(name: String) -> String {
        #"{"name":"\#(name)","type":"regular","dependencies":[],"resources":[{"rule":{"process":{}},"path":"asset.txt"}]}"#
    }

}
