/// A Swift version with unsigned major, minor, and patch components.
public struct SwiftVersion: Sendable, Hashable {

    /// The major version component.
    public let major: UInt

    /// The minor version component.
    public let minor: UInt

    /// The patch version component.
    public let patch: UInt

    /// Creates a Swift version from unsigned major, minor, and patch components.
    public init(major: UInt, minor: UInt, patch: UInt) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

}

extension SwiftVersion: LosslessStringConvertible {

    /// Creates a Swift version from two or three ASCII decimal components.
    /// Returns `nil` if the text does not use a supported format.
    public init?(_ description: String) {

        let components = description.split(separator: ".", omittingEmptySubsequences: false)

        guard components.count == 2 || components.count == 3 else { return nil }
        guard components.allSatisfy(\.isASCIIDecimal) else { return nil }

        guard let major = UInt(components[0]) else { return nil }
        guard let minor = UInt(components[1]) else { return nil }

        if components.count == 3 {
            guard let patch = UInt(components[2]) else { return nil }
            self.init(major: major, minor: minor, patch: patch)
        } else {
            self.init(major: major, minor: minor, patch: 0)
        }
    }

    /// The version in `major.minor.patch` format.
    public var description: String {
        "\(major).\(minor).\(patch)"
    }

}

extension SwiftVersion: Comparable {

    /// Returns `true` if the left version is less than the right version in major, minor, and patch order.
    public static func < (lhs: SwiftVersion, rhs: SwiftVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }

        return lhs.patch < rhs.patch
    }

}

extension Substring {

    fileprivate var isASCIIDecimal: Bool {
        !isEmpty && utf8.allSatisfy { (48...57).contains($0) }
    }

}
