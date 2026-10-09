import Foundation

extension PackageDescription {

    struct Description: Decodable {

        let products: [Product]
        let targets: [Target]

    }

}

extension PackageDescription {

    struct DynamicCodingKey: CodingKey {

        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }

    }

}

extension DecodingError {

    static func invalidIdentifier(at codingPath: [CodingKey]) -> Self {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: "Expected a nonempty identifier."))
    }

    static func invalidUnion(at codingPath: [CodingKey], named name: String) -> Self {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: "Expected exactly one \(name) case."))
    }

}
