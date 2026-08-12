import Testing
@testable import SwiftlyKit

@Suite("Executable products")
struct ExecutableProductsTests {

    @Test("Named selection returns the matching product")
    func namedSelection() throws {

        let products = ExecutableProducts([
            ExecutableProduct(name: "First"),
            ExecutableProduct(name: "Second")
        ])

        #expect(try products.select("Second").name == "Second")
        #expect(products.map(\.name) == ["First", "Second"])
    }

    @Test("Unnamed selection returns the sole product")
    func soleSelection() throws {

        let products = ExecutableProducts([ExecutableProduct(name: "Tool")])

        #expect(try products.select().name == "Tool")
    }

    @Test("Named selection reports an absent product")
    func missingNamedSelection() {

        let products = ExecutableProducts([ExecutableProduct(name: "Tool")])

        #expect(throws: SwiftlyKitError.executableProductNotFound("Missing")) {
            try products.select("Missing")
        }
    }

    @Test("Unnamed selection reports zero or multiple products")
    func unavailableSoleSelection() {

        let emptyProducts = ExecutableProducts([])
        let multipleProducts = ExecutableProducts([
            ExecutableProduct(name: "First"),
            ExecutableProduct(name: "Second")
        ])

        #expect(throws: SwiftlyKitError.executableProductSelectionRequired([])) {
            try emptyProducts.select()
        }
        #expect(throws: SwiftlyKitError.executableProductSelectionRequired(["First", "Second"])) {
            try multipleProducts.select()
        }
    }

}
