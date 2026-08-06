import Foundation

/// An executable product discovered from a Swift package.
public struct ExecutableProduct: Sendable, Hashable {
    public let name: String

    init(name: String) {
        self.name = name
    }
}

/// Describes one executable build.
public struct BuildRequest: Sendable {
    public let product: ExecutableProduct
    public let packageRoot: URL
    public let target: BuildTarget
    public let configuration: BuildConfiguration
    public let scratchDirectory: URL?
    public let output: URL?
    public let strip: Bool
    public let environment: [String: String]

    public init(
        _ product: ExecutableProduct,
        in packageRoot: URL,
        for target: BuildTarget,
        configuration: BuildConfiguration = .debug,
        scratchDirectory: URL? = nil,
        output: URL? = nil,
        strip: Bool = false,
        environment: [String: String] = [:]
    ) {
        self.product = product
        self.packageRoot = packageRoot
        self.target = target
        self.configuration = configuration
        self.scratchDirectory = scratchDirectory
        self.output = output
        self.strip = strip
        self.environment = environment
    }
}
