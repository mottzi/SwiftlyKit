import Foundation

/// Cross-compilation API that builds verified static Linux executables from trusted local Swift packages.
/// Mutating operations for one user coordinate across values and cooperating processes.
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
        mutationGate: MutationGate = .shared,
        assessor: EnvironmentAssessor,
        preparer: EnvironmentPreparer,
        swiftPM: SwiftPM
    ) {
        self.mutationGate = mutationGate
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

    /// Requests Apple's interactive Command Line Tools installer only if no usable macOS SDK is active.
    /// Returns after macOS accepts the request, not after the installation finishes.
    /// This request is outside mutation coordination and never changes the active developer directory.
    public static func requestCommandLineToolsInstallation() async throws {
        try await HostCLTRequest().request()
    }

}

extension SwiftlyKit {

    /// Returns exact compatible environments from one read-only package and installed-state observation.
    /// Results contain each Swift version once in newest-first order.
    /// Installed-state results can become stale before the caller selects an environment.
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
    
    /// Prepares accepted components and binds one SwiftPM environment snapshot and trait configuration to later operations.
    /// Caller-supplied SwiftPM workflow values do not reach installation or download processes.
    public func prepare(
        _ assessment: EnvironmentAssessment,
        swiftPMEnvironment: SwiftPMEnvironment = .inherited,
        swiftPMTraits: SwiftPMTraits = .packageDefaults,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> LocalBuildEnvironment {

        let snapshot = swiftPMEnvironment.snapshot()
        return try await mutationGate.withAccess {
            try await prepareUnderLease(
                assessment,
                swiftPMEnvironment: snapshot,
                swiftPMTraits: swiftPMTraits,
                onEvent: onEvent
            )
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

        try await mutationGate.withAccess { try await resolveDependenciesUnderLease(using: environment, onEvent: onEvent) }
    }
    
    /// Builds and verifies one executable with the prepared toolchain and SDK.
    /// Disables automatic resolution and throws `dependencyResolutionRequired` if resolution is necessary.
    /// Rejects source or resolved-dependency changes, then applies requested stripping, atomic copying, and cleanup.
    public func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> URL {

        try request.validate()
        return try await mutationGate.withAccess {
            try await buildUnderLease(request, using: environment, onEvent: onEvent)
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
            try await cleanBuildArtifactsUnderLease(in: storage, using: environment, onEvent: onEvent)
        }
    }

    /// Removes the complete selected SwiftPM scratch directory, including dependency storage.
    public func resetBuildStorage(
        in storage: BuildStorage = .packageDefault,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {

        try await mutationGate.withAccess {
            try await resetBuildStorageUnderLease(in: storage, using: environment, onEvent: onEvent)
        }
    }

}

extension SwiftlyKit {

    private func prepareUnderLease(
        _ assessment: EnvironmentAssessment,
        swiftPMEnvironment: SwiftPMEnvironment.Snapshot,
        swiftPMTraits: SwiftPMTraits,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> LocalBuildEnvironment {

        do {
            return try await preparer.prepare(
                assessment,
                swiftPMEnvironment: swiftPMEnvironment,
                swiftPMTraits: swiftPMTraits,
                onEvent: onEvent
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SwiftlyKitError {
            throw error
        } catch let error as EnvironmentPreparationError {
            throw error.swiftlyKitError
        } catch let error as InstalledEnvironmentError {
            throw error.swiftlyKitError
        } catch {
            throw SwiftlyKitError.swiftlyInstallationFailed("An unexpected environment error occurred.")
        }
    }

    private func resolveDependenciesUnderLease(
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws {

        do { try await swiftPM.resolveDependencies(using: environment, onEvent: onEvent) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftlyKitError { throw error }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.dependencyResolutionFailed("An unexpected dependency resolution error occurred.") }
    }

    private func buildUnderLease(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> URL {

        do { return try await swiftPM.build(request, using: environment, onEvent: onEvent) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftlyKitError { throw error }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.buildFailed("An unexpected build error occurred.") }
    }

    private func cleanBuildArtifactsUnderLease(
        in storage: BuildStorage,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws {

        do { try await swiftPM.cleanBuildArtifacts(in: storage, using: environment, onEvent: onEvent) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.buildArtifactCleanupFailed("An unexpected cleanup error occurred.") }
    }

    private func resetBuildStorageUnderLease(
        in storage: BuildStorage,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws {

        do { try await swiftPM.resetBuildStorage(in: storage, using: environment, onEvent: onEvent) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.buildStorageResetFailed("An unexpected cleanup error occurred.") }
    }

}

extension SwiftlyKit {
    
    /// Runs assessment, authorized preparation, product selection, required dependency resolution, and one verified build.
    /// Uses one SwiftPM environment snapshot, trait configuration, and mutation lease for the complete workflow.
    /// Applies toolchain, build resource, and output choices and rejects package source changes during compilation.
    public static func build(
        _ packageRoot: URL,
        product: String? = nil,
        for target: BuildTarget = .linux(.x86_64),
        toolchain: ToolchainSelection = .automatic,
        configuration: BuildConfiguration = .release,
        jobs: Int? = nil,
        storage: BuildStorage = .packageDefault,
        output: BuildOutput = .buildStorage,
        strip: Bool = false,
        swiftPMEnvironment: SwiftPMEnvironment = .inherited,
        swiftPMTraits: SwiftPMTraits = .packageDefaults,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> URL {

        try await SwiftlyKit().build(
            packageRoot,
            product: product,
            for: target,
            toolchain: toolchain,
            configuration: configuration,
            jobs: jobs,
            storage: storage,
            output: output,
            strip: strip,
            swiftPMEnvironment: swiftPMEnvironment,
            swiftPMTraits: swiftPMTraits,
            onEvent: onEvent
        )
    }
    
    /// Runs the fast-track workflow with this facade's dependencies under one mutation lease.
    func build(
        _ packageRoot: URL,
        product productName: String?,
        for target: BuildTarget,
        toolchain: ToolchainSelection = .automatic,
        configuration: BuildConfiguration,
        jobs: Int? = nil,
        storage: BuildStorage = .packageDefault,
        output: BuildOutput = .buildStorage,
        strip: Bool = false,
        swiftPMEnvironment: SwiftPMEnvironment = .inherited,
        swiftPMTraits: SwiftPMTraits = .packageDefaults,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> URL {

        try BuildRequest.validate(jobs: jobs)
        let snapshot = swiftPMEnvironment.snapshot()
        return try await mutationGate.withAccess {
            try await buildUnderLease(
                packageRoot,
                product: productName,
                for: target,
                toolchain: toolchain,
                configuration: configuration,
                jobs: jobs,
                storage: storage,
                output: output,
                strip: strip,
                swiftPMEnvironment: snapshot,
                swiftPMTraits: swiftPMTraits,
                onEvent: onEvent
            )
        }
    }

    private func buildUnderLease(
        _ packageRoot: URL,
        product productName: String?,
        for target: BuildTarget,
        toolchain: ToolchainSelection,
        configuration: BuildConfiguration,
        jobs: Int?,
        storage: BuildStorage,
        output: BuildOutput,
        strip: Bool,
        swiftPMEnvironment: SwiftPMEnvironment.Snapshot,
        swiftPMTraits: SwiftPMTraits,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> URL {

        let assessment = try await assess(packageRoot, for: target, toolchain: toolchain)
        let environment = try await prepareUnderLease(
            assessment,
            swiftPMEnvironment: swiftPMEnvironment,
            swiftPMTraits: swiftPMTraits,
            onEvent: onEvent
        )
        let products = try await executableProducts(using: environment)
        let product = try products.select(productName)
        let request = BuildRequest(
            product,
            configuration: configuration,
            jobs: jobs,
            storage: storage,
            output: output,
            strip: strip
        )

        do {
            return try await buildUnderLease(request, using: environment, onEvent: onEvent)
        } catch SwiftlyKitError.dependencyResolutionRequired {
            try await resolveDependenciesUnderLease(using: environment, onEvent: onEvent)
            return try await buildUnderLease(request, using: environment, onEvent: onEvent)
        }
    }

}
