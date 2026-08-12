import Foundation

/// Build options for one discovered executable product.
public struct BuildRequest: Sendable {

    /// The executable product to build.
    public let product: ExecutableProduct
    
    /// The SwiftPM build configuration.
    public let configuration: BuildConfiguration
    
    /// The SwiftPM scratch storage used by the build.
    public let storage: BuildStorage
    
    /// The location and post-copy lifecycle of the executable.
    public let output: BuildOutput
    
    /// A Boolean value that removes all symbols from a copy of the verified executable if `true`.
    /// SwiftlyKit preserves the SwiftPM-produced executable and verifies the stripped result again.
    public let strip: Bool
    
    /// Additional environment values for build, bin-path, and strip commands.
    /// SwiftlyKit preserves protected home and Swiftly values.
    public let environment: [String: String]

    /// Creates a request for one discovered executable product.
    /// Defaults to a debug build in package `.build` without stripping, copying, cleanup, or environment additions.
    public init(
        _ product: ExecutableProduct,
        configuration: BuildConfiguration = .debug,
        storage: BuildStorage = .packageDefault,
        output: BuildOutput = .buildStorage,
        strip: Bool = false,
        environment: [String: String] = [:]
    ) {
        self.product = product
        self.configuration = configuration
        self.storage = storage
        self.output = output
        self.strip = strip
        self.environment = environment
    }

}
