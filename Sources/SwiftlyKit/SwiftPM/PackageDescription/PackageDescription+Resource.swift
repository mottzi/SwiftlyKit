import Foundation

extension PackageDescription.Description {

    struct Resource: Decodable {

        let rule: Rule

        init(from decoder: Decoder) throws {

            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try !container.decode(String.self, forKey: .path).isEmpty
            else { throw DecodingError.invalidIdentifier(at: decoder.codingPath + [CodingKeys.path]) }

            rule = try container.decode(Rule.self, forKey: .rule)
        }

    }

}

extension PackageDescription.Description.Resource {

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

extension PackageDescription.Description.Resource {

    private enum CodingKeys: CodingKey {
        case path
        case rule
    }

}
