import Foundation

extension PackageDescription.Description {

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

    }

}

extension PackageDescription.Description.Target {

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
