import Foundation

extension PackageDescription.Description {

    struct Product: Decodable {

        let name: String
        let targets: [String]
        let kind: Kind

        private enum CodingKeys: String, CodingKey {
            case name
            case targets
            case kind = "type"
        }

    }

}

extension PackageDescription.Description.Product {

    enum Kind: Equatable, Decodable {

        case executable
        case library
        case unknown

        init(from decoder: Decoder) throws {

            let container = try decoder.container(keyedBy: PackageDescription.DynamicCodingKey.self)

            guard container.allKeys.count == 1, let key = container.allKeys.first
            else { throw DecodingError.invalidUnion(at: decoder.codingPath, named: "product type") }

            switch key.stringValue {
                case "executable":
                    guard try container.decodeNil(forKey: key)
                    else { throw DecodingError.invalidUnion(at: decoder.codingPath, named: "executable product") }
                    self = .executable

                case "library":
                    let values = try container.decode([String].self, forKey: key)
                    guard values.count == 1, let value = values.first, !value.isEmpty
                    else { throw DecodingError.invalidUnion(at: decoder.codingPath, named: "library product") }
                    self = .library

                default:
                    self = .unknown
            }
        }

    }

}
