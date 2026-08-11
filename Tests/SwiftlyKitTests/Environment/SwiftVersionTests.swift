import Testing
@testable import SwiftlyKit

@Suite("Swift version")
struct SwiftVersionTests {

    @Test("Versions describe and compare numerically")
    func descriptionAndOrdering() {

        let patch = SwiftVersion(major: 6, minor: 1, patch: 1)
        let minor = SwiftVersion(major: 6, minor: 2, patch: 0)
        let major = SwiftVersion(major: 7, minor: 0, patch: 0)

        #expect(patch.description == "6.1.1")
        #expect(patch < minor)
        #expect(minor < major)
        #expect(SwiftVersion(major: 6, minor: 2, patch: 0) == minor)
        #expect(SwiftVersion(major: 6, minor: 2, patch: 1) > minor)
    }

    @Test("Parsing rejects non-semantic selectors")
    func strictParsing() {

        #expect(SwiftVersion(parsing: "6.2") == SwiftVersion(major: 6, minor: 2, patch: 0))
        #expect(SwiftVersion(parsing: "6.2.1") == SwiftVersion(major: 6, minor: 2, patch: 1))

        let values = [
            "",
            "6",
            "6.",
            ".2",
            "6..2",
            "+6.2",
            "6.-2",
            "6.2-rc1",
            "6.2+build",
            "6.2.1.0",
            String(repeating: "9", count: 40) + ".0"
        ]
        for value in values {
            #expect(SwiftVersion(parsing: value) == nil)
        }
    }

}
