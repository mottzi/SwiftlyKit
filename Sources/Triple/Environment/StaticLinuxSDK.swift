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

/// Whether an exact SDK identifier is safe to pass as a command argument.
func isSafeSDKIdentifier(_ identifier: String) -> Bool {
    !identifier.isEmpty
        && !identifier.hasPrefix("-")
        && !identifier.contains("/")
        && !identifier.contains("\\")
        && identifier.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
}
