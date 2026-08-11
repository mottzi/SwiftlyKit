/// An executable product discovered from SwiftPM package metadata.
public struct ExecutableProduct: Sendable, Hashable {

    /// The product name reported by SwiftPM and passed to `swift build --product`.
    public let name: String

}
