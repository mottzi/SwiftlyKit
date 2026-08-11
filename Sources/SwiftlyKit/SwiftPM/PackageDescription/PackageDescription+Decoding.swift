import Foundation

extension PackageDescription {

    struct Description: Decodable {

        let products: [Product]
        let targets: [Target]

    }

}

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

    struct Target: Decodable {

        let name: String
        let kind: Kind
        let dependencies: [Dependency]
        let resources: [Resource]

        private enum CodingKeys: String, CodingKey {
            case name
            case kind = "type"
            case dependencies
            case resources
        }

        enum Kind: Equatable, Decodable {

            case executable
            case unknown

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                guard !value.isEmpty else { throw DecodingError.invalidIdentifier(at: decoder.codingPath) }

                self = value == "executable" ? .executable : .unknown
            }

        }

    }

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

    struct Resource: Decodable {

        let rule: Rule

        private enum CodingKeys: CodingKey {
            case path
            case rule
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let path = try container.decode(String.self, forKey: .path)
            guard !path.isEmpty else { throw DecodingError.invalidIdentifier(at: decoder.codingPath + [CodingKeys.path]) }

            rule = try container.decode(Rule.self, forKey: .rule)
        }

        enum Rule: Decodable {

            case copy
            case embedInCode
            case process
            case unknown

            init(from decoder: Decoder) throws {

                let container = try decoder.container(keyedBy: PackageDescription.DynamicCodingKey.self)
                guard container.allKeys.count == 1, let key = container.allKeys.first
                else { throw DecodingError.invalidUnion(at: decoder.codingPath, named: "resource rule") }

                switch key.stringValue {
                    case "copy":
                        _ = try container.decode(Payload.self, forKey: key)
                        self = .copy
                    case "embedInCode":
                        _ = try container.decode(Payload.self, forKey: key)
                        self = .embedInCode
                    case "process":
                        _ = try container.decode(Payload.self, forKey: key)
                        self = .process
                    default:
                        self = .unknown
                }
            }

            private struct Payload: Decodable {

                init(from decoder: Decoder) throws {
                    _ = try decoder.container(keyedBy: PackageDescription.DynamicCodingKey.self)
                }

            }

        }

    }

}

extension PackageDescription {

    private struct DynamicCodingKey: CodingKey {

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

    fileprivate static func invalidIdentifier(at codingPath: [CodingKey]) -> Self {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: "Expected a nonempty identifier."))
    }

    fileprivate static func invalidUnion(at codingPath: [CodingKey], named name: String) -> Self {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: "Expected exactly one \(name) case."))
    }

}
