import Foundation

/// Cross-compilation API that builds verified static Linux executables from trusted local Swift packages.
/// Mutating operations for one user coordinate across values and cooperating processes.
public struct SwiftlyKit: Sendable {
    
    private let mutationGate: MutationGate
    private let assessor: EnvironmentAssessor
    private let preparer: EnvironmentPreparer
    private let remover: EnvironmentRemover
    private let swiftPM: SwiftPM
    
    /// Creates a SwiftlyKit instance for the current host and user environment.
    public init() {
        self.init(
            assessor: EnvironmentAssessor(),
            preparer: EnvironmentPreparer(),
            swiftPM: SwiftPM(),
            remover: EnvironmentRemover()
        )
    }

    init(
        mutationGate: MutationGate = .shared,
        assessor: EnvironmentAssessor,
        preparer: EnvironmentPreparer,
        swiftPM: SwiftPM,
        remover: EnvironmentRemover = EnvironmentRemover()
    ) {
        self.mutationGate = mutationGate
        self.assessor = assessor
        self.preparer = preparer
        self.remover = remover
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
    public func compatibleEnvironments(_ packageRoot: URL, for target: BuildTarget) async throws -> EnvironmentChoices {
        
        try await assessor.compatibleEnvironments(packageRoot, for: target)
    }

    /// Selects an exact official toolchain and matching Static Linux SDK without changing package or installed state.
    /// Uses validated cached metadata only to reuse a complete installed pair during a catalog outage.
    /// Captures `Package.swift` and the nearest `.swift-version` file so preparation can validate the same inputs.
    public func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection = .automatic
    ) async throws -> EnvironmentAssessment {
        
        try await assessor.assess(packageRoot, for: target, toolchain: toolchain)
    }
    
    /// Prepares accepted components and binds SwiftPM configuration to later operations.
    /// An optional recorder receives each conservative removal plan before toolchain or SDK installation.
    /// Caller-supplied SwiftPM workflow values do not reach installation or download processes.
    public func prepare(
        _ assessment: EnvironmentAssessment,
        swiftPMEnvironment: SwiftPMEnvironment = .inherited,
        swiftPMTraits: SwiftPMTraits = .packageDefaults,
        swiftPMSharedStorage: SwiftPMSharedStorage = .standard,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder? = nil,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> LocalBuildEnvironment {

        let snapshot = swiftPMEnvironment.snapshot()

        do {
            return try await mutationGate.withAccess {
                try await prepareUnderLease(
                    assessment,
                    swiftPMEnvironment: snapshot,
                    swiftPMTraits: swiftPMTraits,
                    swiftPMSharedStorage: swiftPMSharedStorage,
                    recordRemovalPlan: recordRemovalPlan,
                    onEvent: onEvent
                )
            }
        } catch let error as EnvironmentPlanRecordingError {
            throw error.underlying
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SwiftlyKitError {
            throw error
        } catch {
            throw SwiftlyKitError.mutationCoordinationFailed("An unexpected coordination error occurred.")
        }
    }

    /// Returns explicit and implicit executable products in name order without resolving package dependencies.
    public func executableProducts(using environment: LocalBuildEnvironment) async throws -> ExecutableProducts {

        try await executableProducts(using: environment, scratchStorage: .packageDefault)
    }
    
    /// Runs SwiftPM dependency resolution with the prepared toolchain and selected scratch storage.
    /// This operation can access the network and create or update `Package.resolved`.
    public func resolveDependencies(
        in scratchStorage: SwiftPMScratchStorage = .packageDefault,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {

        try await mutationGate.withAccess {
            try await resolveDependenciesUnderLease(
                in: scratchStorage,
                using: environment,
                onEvent: onEvent
            )
        }
    }
    
    /// Builds and verifies one executable with the prepared toolchain and SDK, and returns its runnable result.
    /// Disables automatic resolution and throws `dependencyResolutionRequired` if resolution is necessary.
    /// Rejects source or resolved-dependency changes, then applies requested stripping, publication, and cleanup.
    public func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> BuildResult {

        try request.validate()
        return try await mutationGate.withAccess {
            try await buildUnderLease(request, using: environment, onEvent: onEvent)
        }
    }

    /// Removes compiled products and intermediates from the selected SwiftPM scratch storage.
    /// Retains package checkouts, repository clones, downloaded artifacts, and workspace state.
    public func cleanBuildArtifacts(
        in storage: SwiftPMScratchStorage = .packageDefault,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {

        try await mutationGate.withAccess {
            try await cleanBuildArtifactsUnderLease(in: storage, using: environment, onEvent: onEvent)
        }
    }

    /// Removes the complete selected SwiftPM scratch directory, including dependency storage.
    public func resetBuildStorage(
        in storage: SwiftPMScratchStorage = .packageDefault,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {

        try await mutationGate.withAccess {
            try await resetBuildStorageUnderLease(in: storage, using: environment, onEvent: onEvent)
        }
    }

}

extension SwiftlyKit {

    private func executableProducts(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage
    ) async throws -> ExecutableProducts {

        do {
            return ExecutableProducts(try await swiftPM.executableProducts(
                using: environment,
                scratchStorage: scratchStorage
            ))
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftlyKitError { throw error }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.packageInspectionFailed("An unexpected package error occurred.") }
    }

    private func prepareUnderLease(
        _ assessment: EnvironmentAssessment,
        swiftPMEnvironment: SwiftPMEnvironment.Snapshot,
        swiftPMTraits: SwiftPMTraits,
        swiftPMSharedStorage: SwiftPMSharedStorage,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder?,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> LocalBuildEnvironment {

        try await preparer.prepare(
            assessment,
            swiftPMEnvironment: swiftPMEnvironment,
            swiftPMTraits: swiftPMTraits,
            swiftPMSharedStorage: swiftPMSharedStorage,
            recordRemovalPlan: recordRemovalPlan,
            onEvent: onEvent
        )
    }

    private func resolveDependenciesUnderLease(
        in scratchStorage: SwiftPMScratchStorage,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws {

        do {
            try await swiftPM.resolveDependencies(
                in: scratchStorage,
                using: environment,
                onEvent: onEvent
            )
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftlyKitError { throw error }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.dependencyResolutionFailed("An unexpected dependency resolution error occurred.") }
    }

    private func buildUnderLease(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> BuildResult {

        do { return try await swiftPM.build(request, using: environment, onEvent: onEvent) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftlyKitError { throw error }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.buildFailed("An unexpected build error occurred.") }
    }

    private func cleanBuildArtifactsUnderLease(
        in storage: SwiftPMScratchStorage,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws {

        do { try await swiftPM.cleanBuildArtifacts(in: storage, using: environment, onEvent: onEvent) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftPMError { throw error.swiftlyKitError }
        catch { throw SwiftlyKitError.buildArtifactCleanupFailed("An unexpected cleanup error occurred.") }
    }

    private func resetBuildStorageUnderLease(
        in storage: SwiftPMScratchStorage,
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

    /// Removes one exact environment plan with this facade's dependencies under one mutation lease.
    func removeEnvironment(_ plan: EnvironmentRemovalPlan, onEvent: SwiftlyKitEvent.Handler? = nil) async throws {

        try await mutationGate.withAccess {
            try await remover.remove(plan, onEvent: onEvent)
        }
    }

}

extension SwiftlyKit {
    
    /// Removes exact Swift toolchain and Static Linux SDK resources without retaining state.
    /// Rechecks live state, treats observable absent targets as success, and refuses unsafe requests.
    /// Removes an SDK before its paired toolchain for a full environment plan.
    public static func remove(_ plan: EnvironmentRemovalPlan, onEvent: SwiftlyKitEvent.Handler? = nil) async throws {

        try await SwiftlyKit().removeEnvironment(plan, onEvent: onEvent)
    }

    /// Runs the complete fast track for one verified build and returns its runnable result.
    /// Uses one SwiftPM environment, trait, and shared-storage configuration for the complete workflow.
    /// Applies build choices and can record removal plans before toolchain or SDK installation.
    public static func build(
        _ packageRoot: URL,
        product: String? = nil,
        for target: BuildTarget = .linux(.x86_64),
        toolchain: ToolchainSelection = .automatic,
        configuration: BuildConfiguration = .release,
        jobs: Int? = nil,
        scratchStorage: SwiftPMScratchStorage = .packageDefault,
        output: BuildOutput = .buildStorage,
        strip: Bool = false,
        swiftPMEnvironment: SwiftPMEnvironment = .inherited,
        swiftPMTraits: SwiftPMTraits = .packageDefaults,
        swiftPMSharedStorage: SwiftPMSharedStorage = .standard,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder? = nil,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> BuildResult {

        try await SwiftlyKit().build(
            packageRoot,
            product: product,
            for: target,
            toolchain: toolchain,
            configuration: configuration,
            jobs: jobs,
            scratchStorage: scratchStorage,
            output: output,
            strip: strip,
            swiftPMEnvironment: swiftPMEnvironment,
            swiftPMTraits: swiftPMTraits,
            swiftPMSharedStorage: swiftPMSharedStorage,
            recordRemovalPlan: recordRemovalPlan,
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
        scratchStorage: SwiftPMScratchStorage = .packageDefault,
        output: BuildOutput = .buildStorage,
        strip: Bool = false,
        swiftPMEnvironment: SwiftPMEnvironment = .inherited,
        swiftPMTraits: SwiftPMTraits = .packageDefaults,
        swiftPMSharedStorage: SwiftPMSharedStorage = .standard,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder? = nil,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> BuildResult {

        try BuildRequest.validate(jobs: jobs)
        let snapshot = swiftPMEnvironment.snapshot()
        do {
            return try await mutationGate.withAccess {
                try await buildUnderLease(
                    packageRoot,
                    product: productName,
                    for: target,
                    toolchain: toolchain,
                    configuration: configuration,
                    jobs: jobs,
                    scratchStorage: scratchStorage,
                    output: output,
                    strip: strip,
                    swiftPMEnvironment: snapshot,
                    swiftPMTraits: swiftPMTraits,
                    swiftPMSharedStorage: swiftPMSharedStorage,
                    recordRemovalPlan: recordRemovalPlan,
                    onEvent: onEvent
                )
            }
        } catch let error as EnvironmentPlanRecordingError {
            throw error.underlying
        }
    }

    private func buildUnderLease(
        _ packageRoot: URL,
        product productName: String?,
        for target: BuildTarget,
        toolchain: ToolchainSelection,
        configuration: BuildConfiguration,
        jobs: Int?,
        scratchStorage: SwiftPMScratchStorage,
        output: BuildOutput,
        strip: Bool,
        swiftPMEnvironment: SwiftPMEnvironment.Snapshot,
        swiftPMTraits: SwiftPMTraits,
        swiftPMSharedStorage: SwiftPMSharedStorage,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder?,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> BuildResult {

        let assessment = try await assess(packageRoot, for: target, toolchain: toolchain)
        let environment = try await prepareUnderLease(
            assessment,
            swiftPMEnvironment: swiftPMEnvironment,
            swiftPMTraits: swiftPMTraits,
            swiftPMSharedStorage: swiftPMSharedStorage,
            recordRemovalPlan: recordRemovalPlan,
            onEvent: onEvent
        )
        let products = try await executableProducts(
            using: environment,
            scratchStorage: scratchStorage
        )
        let product = try products.select(productName)
        let request = BuildRequest(
            product,
            configuration: configuration,
            jobs: jobs,
            scratchStorage: scratchStorage,
            output: output,
            strip: strip
        )

        do {
            return try await buildUnderLease(request, using: environment, onEvent: onEvent)
        } catch SwiftlyKitError.dependencyResolutionRequired {
            try await resolveDependenciesUnderLease(
                in: scratchStorage,
                using: environment,
                onEvent: onEvent
            )
            return try await buildUnderLease(request, using: environment, onEvent: onEvent)
        }
    }

}
