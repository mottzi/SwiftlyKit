import Foundation

/// Output-specific build options for one discovered executable product.
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
    
    /// Creates a request for one discovered executable product.
    /// Defaults to a debug build in package `.build` without stripping, copying, or cleanup.
    public init(
        _ product: ExecutableProduct,
        configuration: BuildConfiguration = .debug,
        storage: BuildStorage = .packageDefault,
        output: BuildOutput = .buildStorage,
        strip: Bool = false
    ) {
        self.product = product
        self.configuration = configuration
        self.storage = storage
        self.output = output
        self.strip = strip
    }

}
