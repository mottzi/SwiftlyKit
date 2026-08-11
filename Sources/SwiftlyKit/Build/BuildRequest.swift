import Foundation

/// Build options for one discovered executable product.
public struct BuildRequest: Sendable {

    /// The executable product to build.
    public let product: ExecutableProduct
    
    /// The SwiftPM build configuration.
    public let configuration: BuildConfiguration
    
    /// An optional SwiftPM scratch directory instead of the package default.
    /// SwiftlyKit retains exact-SDK selection metadata inside the effective scratch directory.
    public let scratchDirectory: URL?
    
    /// The optional file URL for atomic publication.
    /// The destination must not exist, and its parent directory must exist.
    public let output: URL?
    
    /// A Boolean value that removes all symbols from the verified executable if `true`.
    /// SwiftlyKit verifies the executable again after stripping.
    public let strip: Bool
    
    /// Additional environment values for build, bin-path, and strip commands.
    /// SwiftlyKit preserves protected home and Swiftly values.
    public let environment: [String: String]

    /// Creates a request for one discovered executable product.
    /// Defaults to a debug build in package `.build` without stripping, publication, or environment additions.
    public init(
        _ product: ExecutableProduct,
        configuration: BuildConfiguration = .debug,
        scratchDirectory: URL? = nil,
        output: URL? = nil,
        strip: Bool = false,
        environment: [String: String] = [:]
    ) {
        self.product = product
        self.configuration = configuration
        self.scratchDirectory = scratchDirectory
        self.output = output
        self.strip = strip
        self.environment = environment
    }

}
