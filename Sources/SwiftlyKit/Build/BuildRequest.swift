import Foundation

/// The build choices for one discovered executable product.
public struct BuildRequest: Sendable {

    /// The executable product to build.
    public let product: ExecutableProduct
    
    /// The SwiftPM build configuration.
    public let configuration: BuildConfiguration

    /// The maximum number of concurrent SwiftPM build jobs, or `nil` to use the SwiftPM default.
    public let jobs: Int?
    
    /// The SwiftPM scratch storage used by the build.
    public let storage: BuildStorage
    
    /// The location and post-publication lifecycle of the runnable output.
    public let output: BuildOutput
    
    /// A Boolean value that removes all symbols from a SwiftlyKit-owned executable if `true`.
    /// SwiftlyKit preserves the SwiftPM-produced executable and verifies the stripped result again.
    public let strip: Bool
    
    /// Creates a request for one discovered executable product.
    /// Defaults to a release build in package `.build` with SwiftPM's concurrent-job default.
    /// The default does not strip, publish, or clean the output.
    public init(
        _ product: ExecutableProduct,
        configuration: BuildConfiguration = .release,
        jobs: Int? = nil,
        storage: BuildStorage = .packageDefault,
        output: BuildOutput = .buildStorage,
        strip: Bool = false
    ) {
        self.product = product
        self.configuration = configuration
        self.jobs = jobs
        self.storage = storage
        self.output = output
        self.strip = strip
    }

}

extension BuildRequest {

    /// Rejects a nonpositive explicit SwiftPM build job count.
    func validate() throws {
        try Self.validate(jobs: jobs)
    }

    /// Rejects a nonpositive optional SwiftPM build job count.
    static func validate(jobs: Int?) throws {
        guard let jobs else { return }
        guard jobs > 0 else { throw SwiftlyKitError.invalidBuildJobCount(jobs) }
    }

}
