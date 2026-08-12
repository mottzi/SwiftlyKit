import Foundation

func packageDescriptionJSON(executableProducts productNames: [String]) throws -> String {

    let fixture = PackageDescriptionFixture(
        products: productNames.map(PackageDescriptionFixture.Product.init(name:)),
        targets: productNames.map(PackageDescriptionFixture.Target.init(name:))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(fixture)
    return String(decoding: data, as: UTF8.self)
}

private struct PackageDescriptionFixture: Encodable {

    let products: [Product]
    let targets: [Target]

    struct Product: Encodable {

        let name: String
        let targets: [String]
        let type = ProductType()

        init(name: String) {
            self.name = name
            targets = [name]
        }

    }

    struct ProductType: Encodable {

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNil(forKey: .executable)
        }

        private enum CodingKeys: String, CodingKey {
            case executable
        }

    }

    struct Target: Encodable {

        let name: String
        let type = "executable"
        let dependencies: [String] = []
        let resources: [String] = []

    }

}
