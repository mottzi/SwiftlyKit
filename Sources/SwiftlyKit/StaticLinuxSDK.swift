/// An exact official Static Linux SDK paired with a Swift release.
public struct StaticLinuxSDK: Sendable, Hashable {
    
    public let identifier: String
    public let version: String
    
    init(identifier: String, version: String) {
        self.identifier = identifier
        self.version = version
    }
    
}
