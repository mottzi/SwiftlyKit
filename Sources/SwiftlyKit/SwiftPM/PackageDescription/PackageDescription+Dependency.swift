import Foundation

extension PackageDescription.Description {

    enum Dependency: Decodable {

        case target(String)
        case byName(String)
        case product(String)
        case unknown

        init(from decoder: Decoder) throws {

            let container = try decoder.container(keyedBy: PackageDescription.DynamicCodingKey.self)

            guard container.allKeys.count == 1, let key = container.allKeys.first
            else { throw DecodingError.invalidUnion(at: decoder.codingPath, named: "target dependency") }

            switch key.stringValue {
                case "target": self = .target(try container.decode(Reference.self, forKey: key).name)
                case "byName": self = .byName(try container.decode(Reference.self, forKey: key).name)
                case "product": self = .product(try container.decode(Reference.self, forKey: key).name)
                default: self = .unknown
            }
        }

        private struct Reference: Decodable {

            let name: String

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                name = try container.decode(String.self)
                guard !name.isEmpty else { throw DecodingError.invalidIdentifier(at: decoder.codingPath) }
            }

        }

    }

}
