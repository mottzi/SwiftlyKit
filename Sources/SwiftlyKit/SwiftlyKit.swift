import Foundation

/// Cross-compilation API that builds verified static Linux executables from trusted local Swift packages.
/// Each initialization creates a mutation gate that its copies share.
/// The gate serializes environment preparation, dependency resolution, and builds.
public struct SwiftlyKit: Sendable {
    
    private let mutationGate: MutationGate
    private let assessor: EnvironmentAssessor
    private let preparer: EnvironmentPreparer
    private let swiftPM: SwiftPM
    
    /// Creates a SwiftlyKit instance for the current host and user environment.
    public init() {
        self.init(
            assessor: EnvironmentAssessor(),
            preparer: EnvironmentPreparer(),
            swiftPM: SwiftPM()
        )
    }

    init(
        assessor: EnvironmentAssessor,
        preparer: EnvironmentPreparer,
        swiftPM: SwiftPM
    ) {
        self.mutationGate = MutationGate()
        self.assessor = assessor
        self.preparer = preparer
        self.swiftPM = swiftPM
    }

    /// Requests Apple's interactive Command Line Tools installer on a supported host if no usable macOS SDK is active.
    /// Returns after macOS accepts the request, not after the installation finishes.
    /// Skips the request if active developer tools provide a usable SDK and never changes the active developer directory.
    public static func requestCommandLineToolsInstallation() async throws {
        try await HostCLTInstaller().request()
    }

}

extension SwiftlyKit {

    /// Selects an exact official toolchain and matching Static Linux SDK without changing package or installed state.
    /// Captures `Package.swift` and the nearest `.swift-version` file so preparation can validate the same inputs.
    public func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection = .automatic
    ) async throws -> EnvironmentAssessment {
        try await assessor.assess(packageRoot, for: target, toolchain: toolchain)
    }
    
    /// Revalidates an assessment, installs only its required components, and returns the bound build environment.
    /// Passing the assessment authorizes every component in its `requiredComponents` property.
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
    
    /// Returns explicit and implicit executable products in name order without resolving package dependencies.
    public func executableProducts(using environment: LocalBuildEnvironment) async throws -> [ExecutableProduct] {
        
        do { return try await swiftPM.executableProducts(using: environment) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftlyKitError { throw error }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.packageInspectionFailed("An unexpected package error occurred.") }
    }
    
    /// Runs SwiftPM dependency resolution with the prepared toolchain.
    /// This operation can access the network and create or update `Package.resolved`.
    public func resolveDependencies(using environment: LocalBuildEnvironment, onEvent: EventHandler? = nil) async throws {
        
        try await mutationGate.withAccess {
            do { try await swiftPM.resolveDependencies(using: environment, onEvent: onEvent) }
            catch is CancellationError { throw CancellationError() }
            catch let error as SwiftlyKitError { throw error }
            catch let error as SwiftPMError { throw error.swiftlyKitError }
            catch { throw SwiftlyKitError.dependencyResolutionFailed("An unexpected dependency resolution error occurred.") }
        }
    }
    
    /// Builds and verifies one executable with the prepared toolchain and SDK.
    /// Disables automatic dependency resolution and throws `dependencyResolutionRequired` if resolution is necessary.
    /// Strips the executable if requested and publishes it atomically if an output URL is present.
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
    
    /// Prepares the required environment, resolves dependencies if necessary, and builds one verified executable.
    /// Authorizes required component installation and resolves dependencies once before a build retry.
    /// Requires exactly one executable product if `product` is `nil`.
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
