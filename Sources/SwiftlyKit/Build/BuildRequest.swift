import Foundation

/// Describes one executable build.
public struct BuildRequest: Sendable {

    /// The executable product to build.
    public let product: ExecutableProduct
    
    /// The SwiftPM build configuration.
    public let configuration: BuildConfiguration
    
    /// An optional SwiftPM scratch directory instead of the package default.
    public let scratchDirectory: URL?
    
    /// An optional publication destination that must not already exist.
    public let output: URL?
    
    /// Whether to strip the verified executable before publication.
    public let strip: Bool
    
    /// Additional subprocess environment values. SwiftlyKit preserves its required home and Swiftly values.
    public let environment: [String: String]

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
