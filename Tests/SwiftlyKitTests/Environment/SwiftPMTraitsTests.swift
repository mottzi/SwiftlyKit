import Testing
@testable import SwiftlyKit

@Suite("SwiftPM package traits")
struct SwiftPMTraitsTests {

    @Test("Package defaults, no traits, and all traits map to distinct SwiftPM options")
    func completeSelections() {

        #expect(SwiftPMTraits.packageDefaults.arguments == [])
        #expect(SwiftPMTraits.none.arguments == ["--disable-default-traits"])
        #expect(SwiftPMTraits.all.arguments == ["--enable-all-traits"])
        #expect(SwiftPMTraits.packageDefaults.arguments != SwiftPMTraits.none.arguments)
        #expect(SwiftPMTraits.none.arguments != SwiftPMTraits.all.arguments)
    }

    @Test("Explicit names are validated, deduplicated, ordered, and can include defaults")
    func selectedTraits() throws {

        var names = ["Zebra", "Alpha", "Zebra"]
        let withoutDefaults = try SwiftPMTraits(
            names,
            includingDefaults: false
        )
        let withDefaults = try SwiftPMTraits(
            names,
            includingDefaults: true
        )
        names.append("Changed")

        #expect(withoutDefaults.arguments == ["--traits", "Alpha,Zebra"])
        #expect(withDefaults.arguments == ["--traits", "Alpha,Zebra,default"])
        #expect(withoutDefaults.arguments != withDefaults.arguments)
    }

    @Test("An empty explicit selection normalizes to its matching complete selection")
    func emptySelection() throws {

        #expect(try SwiftPMTraits([], includingDefaults: true).arguments == SwiftPMTraits.packageDefaults.arguments)
        #expect(try SwiftPMTraits([], includingDefaults: false).arguments == SwiftPMTraits.none.arguments)
    }

    @Test("Unicode letters, combining marks, hyphens, and plus signs use documented trait syntax")
    func documentedSyntax() throws {

        _ = try SwiftPMTraits(
            ["Éclair", "e\u{301}tendue", "B-and-C", "Feature+", "_Internal"],
            includingDefaults: false
        )
    }

    @Test(
        "Invalid and reserved trait names are rejected",
        arguments: [
            "", "1Feature", "-Feature", "+Feature", "Feature Value", "Feature,Other",
            "default", "DEFAULT", "defaults", "Defaults"
        ]
    )
    func invalidName(name: String) {

        #expect(throws: SwiftlyKitError.invalidSwiftPMTrait(name)) {
            try SwiftPMTraits([name], includingDefaults: false)
        }
    }

    @Test("Trait failures identify only the invalid name")
    func errorDescription() {

        let error = SwiftlyKitError.invalidSwiftPMTrait("invalid name")
        #expect(error.errorDescription == "The SwiftPM package trait “invalid name” has an invalid or reserved name.")
    }

}
