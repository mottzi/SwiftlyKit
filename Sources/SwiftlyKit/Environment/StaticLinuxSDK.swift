/// The identity and version of an official Static Linux SDK that is paired with a Swift release.
public struct StaticLinuxSDK: Sendable, Hashable {

    /// The artifact bundle identifier for the SDK.
    public let identifier: String

    /// The SDK release version from the Swift.org catalog.
    public let version: String

    init(identifier: String, version: String) {
        self.identifier = identifier
        self.version = version
    }

}
