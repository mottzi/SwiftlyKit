import Foundation

/// Prepares official Swift cross-compilation environments and builds Linux executables.
///
/// The static fast track prepares everything required and selects the sole executable product.
///
/// ```swift
/// let executable = try await SwiftlyKit.build(packageRoot)
/// ```
///
/// Use the staged API to inspect required installations or select from multiple products.
/// Assessing is read-only. Passing the returned assessment to ``prepare(_:onEvent:)`` explicitly authorizes its
/// required installations. The resulting ``LocalBuildEnvironment`` carries the context used by every later operation.
///
/// ```swift
/// let kit = SwiftlyKit()
/// let assessment = try await kit.assess(packageRoot, for: .linux(.arm64))
/// let environment = try await kit.prepare(assessment)
/// let products = try await kit.executableProducts(using: environment)
/// let executable = try await kit.build(
///     BuildRequest(products[0], configuration: .release),
///     using: environment
/// )
/// ```
public struct SwiftlyKit: Sendable {
    
    private let mutationGate: MutationGate
    private let assessor: EnvironmentAssessor
    private let preparer: EnvironmentPreparer
    private let swiftPM: SwiftPM
    
    public init() {
        self.init(
            assessor: EnvironmentAssessor(),
            preparer: EnvironmentPreparer(),
            swiftPM: SwiftPM()
        )
    }

    init(assessor: EnvironmentAssessor, preparer: EnvironmentPreparer, swiftPM: SwiftPM) {

        self.mutationGate = MutationGate()
        self.assessor = assessor
        self.preparer = preparer
        self.swiftPM = swiftPM
    }

    /// Prepares the required environment and builds an executable product in one operation.
    ///
    /// This operation may install Swiftly, a Swift toolchain, or a Static Linux SDK, and may resolve package dependencies.
    /// When `product` is `nil`, the package must declare exactly one executable product.
    public static func build(
        _ packageRoot: URL,
        product: String? = nil,
        for target: BuildTarget = .linux(.x86_64),
        configuration: BuildConfiguration = .release,
        onEvent: EventHandler? = nil
    ) async throws -> URL {

        try await SwiftlyKit().build(
            packageRoot,
            product: product,
            for: target,
            configuration: configuration,
            onEvent: onEvent
        )
    }

    func build(
        _ packageRoot: URL,
        product productName: String?,
        for target: BuildTarget,
        configuration: BuildConfiguration,
        onEvent: EventHandler?
    ) async throws -> URL {

        let assessment = try await assess(packageRoot, for: target)
        let environment = try await prepare(assessment, onEvent: onEvent)
        let products = try await executableProducts(using: environment)
        let product = try selectProduct(named: productName, from: products)
        let request = BuildRequest(product, configuration: configuration)

        do {
            return try await build(request, using: environment, onEvent: onEvent)
        } catch SwiftlyKitError.dependencyResolutionRequired {
            try await resolveDependencies(using: environment, onEvent: onEvent)
            return try await build(request, using: environment, onEvent: onEvent)
        }
    }

}

extension SwiftlyKit {

    /// Assesses the exact environment required by a trusted local package.
    public func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection = .automatic
    ) async throws -> EnvironmentAssessment {
        try await assessor.assess(packageRoot, for: target, toolchain: toolchain)
    }
    
    /// Performs the exact mutations described by an accepted assessment.
    public func prepare(
        _ assessment: EnvironmentAssessment,
        onEvent: EventHandler? = nil
    ) async throws -> LocalBuildEnvironment {
        
        try await mutationGate.withAccess {
            do { return try await preparer.prepare(assessment, onEvent: onEvent) }
            catch is CancellationError { throw CancellationError() }
            catch let error as SwiftlyKitError { throw error }
            catch let error as EnvironmentPreparationError { throw error.swiftlyKitError }
            catch let error as InstalledEnvironmentError { throw error.swiftlyKitError }
            catch { throw SwiftlyKitError.swiftlyInstallationFailed("An unexpected environment error occurred.") }
        }
    }
    
    /// Discovers executable products in the package bound to a prepared environment.
    public func executableProducts(using environment: LocalBuildEnvironment) async throws -> [ExecutableProduct] {
        
        do { return try await swiftPM.executableProducts(using: environment) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftlyKitError { throw error }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.packageInspectionFailed("An unexpected package error occurred.") }
    }
    
    /// Explicitly resolves dependencies in the package bound to a prepared environment.
    public func resolveDependencies(using environment: LocalBuildEnvironment, onEvent: EventHandler? = nil) async throws {
        
        try await mutationGate.withAccess {
            do { try await swiftPM.resolveDependencies(using: environment, onEvent: onEvent) }
            catch is CancellationError { throw CancellationError() }
            catch let error as SwiftlyKitError { throw error }
            catch let error as SwiftPMError { throw error.swiftlyKitError }
            catch { throw SwiftlyKitError.dependencyResolutionFailed("An unexpected dependency resolution error occurred.") }
        }
    }
    
    /// Builds, verifies, and optionally publishes one executable product.
    public func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: EventHandler? = nil
    ) async throws -> URL {
        
        try await mutationGate.withAccess {
            do { return try await swiftPM.build(request, using: environment, onEvent: onEvent) }
            catch is CancellationError { throw CancellationError() }
            catch let error as SwiftlyKitError { throw error }
            catch let error as SwiftPMError { throw error.swiftlyKitError }
            catch { throw SwiftlyKitError.buildFailed("An unexpected build error occurred.") }
        }
    }
    
}

extension SwiftlyKit {

    private func selectProduct(named name: String?, from products: [ExecutableProduct]) throws -> ExecutableProduct {

        if let name {
            guard let namedProduct = products.first(where: { $0.name == name })
            else { throw SwiftlyKitError.executableProductNotFound(name) }
            return namedProduct
        }

        guard products.count == 1, let firstProduct = products.first
        else { throw SwiftlyKitError.executableProductSelectionRequired(products.map(\.name)) }
        return firstProduct
    }

}
