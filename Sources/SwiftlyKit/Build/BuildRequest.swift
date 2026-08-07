import Foundation

/// Describes one executable build.
public struct BuildRequest: Sendable {
    
    public let product: ExecutableProduct
    public let configuration: BuildConfiguration
    public let scratchDirectory: URL?
    public let output: URL?
    public let strip: Bool
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
