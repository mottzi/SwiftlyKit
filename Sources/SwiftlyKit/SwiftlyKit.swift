import Foundation

/// Cross-compilation API that builds verified static Linux executables from trusted local Swift packages.
/// Each initialization creates a mutation gate that its copies share.
/// The gate serializes environment preparation, dependency resolution, builds, and cleanup.
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

    /// Returns support and active developer tools readiness for the current host.
    /// This read-only operation does not require a package.
    /// Throws `CancellationError` if the task is canceled.
    public static func hostReadiness() async throws -> HostReadiness {
        try await HostPreflight().assess()
    }

    /// Requests Apple's interactive Command Line Tools installer on a supported host if no usable macOS SDK is active.
    /// Returns after macOS accepts the request, not after the installation finishes.
    /// Skips the request if active developer tools provide a usable SDK and never changes the active developer directory.
    public static func requestCommandLineToolsInstallation() async throws {
        try await HostCLTRequest().request()
    }

}

extension SwiftlyKit {

    /// Returns exact compatible environments from one read-only package and installed-state observation.
    /// Results contain each Swift version once in newest-first order.
    /// This call can load the Swift.org catalog and inspect installed Swiftly state.
    public func compatibleEnvironments(
        _ packageRoot: URL,
        for target: BuildTarget
    ) async throws -> EnvironmentChoices {
        try await assessor.compatibleEnvironments(packageRoot, for: target)
    }

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
        onEvent: SwiftlyKitEvent.Handler? = nil
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
    public func executableProducts(using environment: LocalBuildEnvironment) async throws -> ExecutableProducts {
        
        do {
            let products = try await swiftPM.executableProducts(using: environment)
            return ExecutableProducts(products)
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftlyKitError { throw error }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.packageInspectionFailed("An unexpected package error occurred.") }
    }
    
    /// Runs SwiftPM dependency resolution with the prepared toolchain.
    /// This operation can access the network and create or update `Package.resolved`.
    public func resolveDependencies(
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {
        
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
    /// Strips the executable if requested, copies it atomically if requested, and then performs requested cleanup.
    public func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> URL {
        
        try await mutationGate.withAccess {
            do { return try await swiftPM.build(request, using: environment, onEvent: onEvent) }
            catch is CancellationError { throw CancellationError() }
            catch let error as SwiftlyKitError { throw error }
            catch let error as SwiftPMError { throw error.swiftlyKitError }
            catch { throw SwiftlyKitError.buildFailed("An unexpected build error occurred.") }
        }
    }

    /// Removes compiled products and intermediates from the selected SwiftPM scratch storage.
    /// Retains package checkouts, repository clones, downloaded artifacts, and workspace state.
    public func cleanBuildArtifacts(
        in storage: BuildStorage = .packageDefault,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {

        try await mutationGate.withAccess {
            do { try await swiftPM.cleanBuildArtifacts(in: storage, using: environment, onEvent: onEvent) }
            catch is CancellationError { throw CancellationError() }
            catch let error as SwiftPMError { throw error.swiftlyKitError }
            catch { throw SwiftlyKitError.buildArtifactCleanupFailed("An unexpected cleanup error occurred.") }
        }
    }

    /// Removes the complete selected SwiftPM scratch directory, including dependency storage.
    public func resetBuildStorage(
        in storage: BuildStorage = .packageDefault,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {

        try await mutationGate.withAccess {
            do { try await swiftPM.resetBuildStorage(in: storage, using: environment, onEvent: onEvent) }
            catch is CancellationError { throw CancellationError() }
            catch let error as SwiftPMError { throw error.swiftlyKitError }
            catch { throw SwiftlyKitError.buildStorageResetFailed("An unexpected cleanup error occurred.") }
        }
    }
    
}

extension SwiftlyKit {
    
    /// Prepares the required environment, resolves dependencies if necessary, and builds one verified executable.
    /// Authorizes required component installation and resolves dependencies once before a build retry.
    /// Requires exactly one executable product if `product` is `nil`.
    /// Selects the requested official toolchain, strips an output copy if requested, and applies `output` storage choices.
    public static func build(
        _ packageRoot: URL,
        product: String? = nil,
        for target: BuildTarget = .linux(.x86_64),
        toolchain: ToolchainSelection = .automatic,
        configuration: BuildConfiguration = .release,
        storage: BuildStorage = .packageDefault,
        output: BuildOutput = .buildStorage,
        strip: Bool = false,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> URL {

        try await SwiftlyKit().build(
            packageRoot,
            product: product,
            for: target,
            toolchain: toolchain,
            configuration: configuration,
            storage: storage,
            output: output,
            strip: strip,
            onEvent: onEvent
        )
    }
    
    func build(
        _ packageRoot: URL,
        product productName: String?,
        for target: BuildTarget,
        toolchain: ToolchainSelection = .automatic,
        configuration: BuildConfiguration,
        storage: BuildStorage = .packageDefault,
        output: BuildOutput = .buildStorage,
        strip: Bool = false,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> URL {

        let assessment = try await assess(packageRoot, for: target, toolchain: toolchain)
        let environment = try await prepare(assessment, onEvent: onEvent)
        let products = try await executableProducts(using: environment)
        let product = try products.select(productName)
        let request = BuildRequest(
            product,
            configuration: configuration,
            storage: storage,
            output: output,
            strip: strip
        )

        do {
            return try await build(request, using: environment, onEvent: onEvent)
        } catch SwiftlyKitError.dependencyResolutionRequired {
            try await resolveDependencies(using: environment, onEvent: onEvent)
            return try await build(request, using: environment, onEvent: onEvent)
        }
    }

}
