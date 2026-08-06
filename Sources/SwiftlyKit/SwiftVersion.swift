/// A stable semantic version of Swift.
public struct SwiftVersion: Sendable, Hashable {
    
    public let major: UInt
    public let minor: UInt
    public let patch: UInt

    public init(major: UInt, minor: UInt, patch: UInt) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

}

extension SwiftVersion: CustomStringConvertible {
    
    public var description: String { "\(major).\(minor).\(patch)" }

}

extension SwiftVersion: Comparable {
    
    public static func < (lhs: SwiftVersion, rhs: SwiftVersion) -> Bool {
        
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        
        return lhs.patch < rhs.patch
    }
    
}
