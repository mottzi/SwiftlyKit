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

extension SwiftVersion {
    
    init?(parsing value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else { return nil }
        guard components.allSatisfy({ component in
            !component.isEmpty && component.utf8.allSatisfy { byte in
                byte >= 48 && byte <= 57
            }
        }) else { return nil }
        
        guard let major = UInt(components[0]),
              let minor = UInt(components[1])
        else { return nil }
        
        let patch: UInt
        if components.count == 3 {
            guard let parsedPatch = UInt(components[2]) else { return nil }
            patch = parsedPatch
        } else {
            patch = 0
        }
        self.init(major: major, minor: minor, patch: patch)
    }
    
}
