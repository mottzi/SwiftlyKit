import Foundation

/// Cross-compilation API that builds verified static Linux executables from trusted local Swift packages.
/// Installed-tool changes and package operations coordinate across values and cooperating processes.
public struct Triple: Sendable {
    
    private let mutationGate: MutationGate
    private let assessor: EnvironmentAssessor
    private let preparer: EnvironmentPreparer
    private let remover: EnvironmentRemover
    private let swiftPM: SwiftPM
    
    /// Creates a stateless Triple facade for one deterministic Swiftly namespace.
    /// The default uses standard per-user locations. A custom root applies to discovery,
    /// preparation, selected-tool commands, and removal plans.
    public init(environmentStorage: EnvironmentStorage = .standard) {
        self.init(
            mutationGate: .shared,
            assessor: EnvironmentAssessor(environmentStorage: environmentStorage),
            preparer: EnvironmentPreparer(),
            swiftPM: SwiftPM(),
            remover: EnvironmentRemover()
        )
    }

    init(
        mutationGate: MutationGate,
        assessor: EnvironmentAssessor,
        preparer: EnvironmentPreparer,
        swiftPM: SwiftPM,
        remover: EnvironmentRemover
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

// MARK: - Convenience API

extension Triple {

    /// Runs the complete convenience workflow with one SwiftPM workflow and selected environment storage.
    /// Applies build choices, can record removal plans before installations, and
    /// returns one verified runnable result.
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
        environmentStorage: EnvironmentStorage = .standard,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder? = nil,
        onEvent: TripleEvent.Handler? = nil
    ) async throws -> BuildResult {

        try await Triple(environmentStorage: environmentStorage).build(
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

}

// MARK: - Staged API

extension Triple {

    /// Returns exact compatible environments from one read-only package and installed-state observation.
    /// Results contain each Swift version once in newest-first order.
    /// During a catalog outage, results are limited to complete installed environments in validated cached metadata.
    public func compatibleEnvironments(_ packageRoot: URL, for target: BuildTarget) async throws -> EnvironmentChoices {
        
        try await mutationGate.withReadAccess {
            try await assessor.compatibleEnvironments(packageRoot, for: target)
        }
    }

    /// Selects an exact official toolchain and matching Static Linux SDK without changing package or installed state.
    /// Uses validated cached metadata only to reuse a complete installed pair during a catalog outage.
    /// Captures `Package.swift` and the nearest `.swift-version` file so preparation can validate the same inputs.
    public func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection = .automatic
    ) async throws -> EnvironmentAssessment {
        
        try await mutationGate.withReadAccess {
            try await assessor.assess(packageRoot, for: target, toolchain: toolchain)
        }
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
        onEvent: TripleEvent.Handler? = nil
    ) async throws -> LocalBuildEnvironment {

        let snapshot = swiftPMEnvironment.snapshot()

        do {
            return try await mutationGate.withPreparationAccess(assessment) {
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
        } catch let error as TripleError {
            throw error
        } catch {
            throw TripleError.mutationCoordinationFailed("An unexpected coordination error occurred.")
        }
    }

    /// Returns explicit and implicit executable products in name order without resolving package dependencies.
    public func executableProducts(using environment: LocalBuildEnvironment) async throws -> ExecutableProducts {

        try await configurePackage(using: environment, scratchStorage: .packageDefault).products
    }

    /// Evaluates the root manifest and returns products with the exact environment that succeeded.
    /// Does not load or resolve dependencies. Builds still validate the complete graph before compilation.
    /// By default, uses stable configuration storage outside the package and its build scratch directory.
    public func configurePackage(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage? = nil,
        onEvent: TripleEvent.Handler? = nil
    ) async throws -> PackageConfiguration {

        let storage = scratchStorage ?? .configuration(for: environment.packageRoot)
        do {
            return try await mutationGate.withConfigurationAccess(using: environment, scratchStorage: storage) {
                try await swiftPM.configurePackage(
                    using: environment,
                    scratchStorage: storage,
                    onEvent: onEvent
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TripleError {
            throw error
        } catch let error as SwiftPMError {
            throw error.tripleError
        } catch {
            throw TripleError.packageInspectionFailed("An unexpected package error occurred.")
        }
    }
    
    /// Inspects root and dependency manifests and returns the environment that successfully evaluated them.
    /// Host SDK recovery preserves the requested Swift version. Resolution requires explicit opt-in.
    public func inspectPackage(
        using environment: LocalBuildEnvironment,
        scratchStorage: SwiftPMScratchStorage = .packageDefault,
        dependencies: DependencyResolutionPolicy = .requireResolved,
        onEvent: TripleEvent.Handler? = nil
    ) async throws -> PackageInspection {

        try await mutationGate.withPackageAccess(using: environment, scratchStorage: scratchStorage) {
            do {
                return try await swiftPM.inspectPackage(
                    using: environment,
                    scratchStorage: scratchStorage,
                    dependencies: dependencies,
                    onEvent: onEvent
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SwiftPMError {
                throw error.tripleError
            }
        }
    }

    /// Runs SwiftPM dependency resolution with the prepared toolchain and selected scratch storage.
    /// This operation can access the network and create or update `Package.resolved`.
    public func resolveDependencies(
        in scratchStorage: SwiftPMScratchStorage = .packageDefault,
        using environment: LocalBuildEnvironment,
        onEvent: TripleEvent.Handler? = nil
    ) async throws {

        try await mutationGate.withPackageAccess(using: environment, scratchStorage: scratchStorage) {
            try await resolveDependenciesUnderLease(
                in: scratchStorage,
                using: environment,
                onEvent: onEvent
            )
        }
    }
    
    /// Builds and verifies one executable with the prepared toolchain and SDK, and returns its runnable result.
    /// Always disables automatic resolution; explicit resolution requires `.resolveIfNeeded`.
    /// Rejects source or resolved-dependency changes, then applies requested stripping, export, and cleanup.
    public func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        dependencies: DependencyResolutionPolicy = .requireResolved,
        onEvent: TripleEvent.Handler? = nil
    ) async throws -> BuildResult {

        try request.validate()
        return try await mutationGate.withPackageAccess(
            using: environment, scratchStorage: request.scratchStorage, output: request.output
        ) {
            try await buildUnderLease(request, using: environment, dependencies: dependencies, onEvent: onEvent)
        }
    }

    /// Removes compiled products and intermediates from the selected SwiftPM scratch storage.
    /// Retains package checkouts, repository clones, downloaded artifacts, and workspace state.
    public func cleanBuildArtifacts(
        in storage: SwiftPMScratchStorage = .packageDefault,
        using environment: LocalBuildEnvironment,
        onEvent: TripleEvent.Handler? = nil
    ) async throws {

        try await mutationGate.withPackageAccess(using: environment, scratchStorage: storage) {
            try await cleanBuildArtifactsUnderLease(in: storage, using: environment, onEvent: onEvent)
        }
    }

    /// Removes the complete selected SwiftPM scratch directory, including dependency storage.
    public func resetBuildStorage(
        in storage: SwiftPMScratchStorage = .packageDefault,
        using environment: LocalBuildEnvironment,
        onEvent: TripleEvent.Handler? = nil
    ) async throws {

        try await mutationGate.withPackageAccess(using: environment, scratchStorage: storage) {
            try await resetBuildStorageUnderLease(in: storage, using: environment, onEvent: onEvent)
        }
    }

}

// MARK: - Environment Removal

extension Triple {

    /// Removes exact Swift toolchain and Static Linux SDK resources without retaining state.
    /// Rechecks live state, treats observable absent targets as success, and refuses unsafe requests.
    /// Removes an SDK before its paired toolchain for a full environment plan.
    public static func remove(_ plan: EnvironmentRemovalPlan, onEvent: TripleEvent.Handler? = nil) async throws {

        try await Triple().removeEnvironment(plan, onEvent: onEvent)
    }

}

// MARK: - Internal Composition

extension Triple {

    /// Runs preparation and package work under separate coordination leases.
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
        onEvent: TripleEvent.Handler?
    ) async throws -> BuildResult {

        try BuildRequest.validate(jobs: jobs)
        let snapshot = swiftPMEnvironment.snapshot()
        do {
            return try await buildPrepared(
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
        } catch let error as EnvironmentPlanRecordingError {
            throw error.underlying
        }
    }

}

extension Triple {

    /// Removes one exact environment plan with this facade's dependencies under one mutation lease.
    func removeEnvironment(_ plan: EnvironmentRemovalPlan, onEvent: TripleEvent.Handler? = nil) async throws {

        try await mutationGate.withAccess {
            try await remover.remove(plan, onEvent: onEvent)
        }
    }

}

// MARK: - Private Mechanics

extension Triple {

    private func buildPrepared(
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
        onEvent: TripleEvent.Handler?
    ) async throws -> BuildResult {

        let choices = try await compatibleEnvironments(packageRoot, for: target)
        var assessment = try choices.select(toolchain)
        while true {
            let selectedAssessment = assessment
            let environment = try await mutationGate.withPreparationAccess(selectedAssessment) {
                try await prepareUnderLease(
                    selectedAssessment,
                    swiftPMEnvironment: swiftPMEnvironment,
                    swiftPMTraits: swiftPMTraits,
                    swiftPMSharedStorage: swiftPMSharedStorage,
                    recordRemovalPlan: recordRemovalPlan,
                    onEvent: onEvent
                )
            }
            do {
                return try await mutationGate.withPackageAccess(
                    using: environment, scratchStorage: scratchStorage, output: output
                ) {
                    let inspection = try await swiftPM.inspectPackage(
                        using: environment,
                        scratchStorage: scratchStorage,
                        dependencies: .resolveIfNeeded,
                        onEvent: onEvent
                    )
                    let product = try inspection.products.select(productName)
                    let request = BuildRequest(
                        product,
                        configuration: configuration,
                        jobs: jobs,
                        scratchStorage: scratchStorage,
                        output: output,
                        strip: strip
                    )
                    return try await swiftPM.buildInspected(
                        request,
                        inspection: inspection,
                        dependencies: .resolveIfNeeded,
                        onEvent: onEvent
                    )
                }
            } catch let error as TripleError {
                guard let recovery = choices.recoveryAssessment(after: error, for: toolchain) else { throw error }
                assessment = recovery
            } catch let error as SwiftPMError {
                throw error.tripleError
            }
        }
    }

}

extension Triple {

    private func prepareUnderLease(
        _ assessment: EnvironmentAssessment,
        swiftPMEnvironment: SwiftPMEnvironment.Snapshot,
        swiftPMTraits: SwiftPMTraits,
        swiftPMSharedStorage: SwiftPMSharedStorage,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder?,
        onEvent: TripleEvent.Handler?
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
        onEvent: TripleEvent.Handler?
    ) async throws {

        do {
            try await swiftPM.resolveDependencies(
                in: scratchStorage,
                using: environment,
                onEvent: onEvent
            )
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as TripleError { throw error }
        catch let error as SwiftPMError { throw error.tripleError }
        catch { throw TripleError.dependencyResolutionFailed("An unexpected dependency resolution error occurred.") }
    }

    private func buildUnderLease(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        dependencies: DependencyResolutionPolicy,
        onEvent: TripleEvent.Handler?
    ) async throws -> BuildResult {

        do {
            return try await swiftPM.build(
                request,
                using: environment,
                dependencies: dependencies,
                onEvent: onEvent
            )
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as TripleError { throw error }
        catch let error as SwiftPMError { throw error.tripleError }
        catch { throw TripleError.buildFailed("An unexpected build error occurred.") }
    }

    private func cleanBuildArtifactsUnderLease(
        in storage: SwiftPMScratchStorage,
        using environment: LocalBuildEnvironment,
        onEvent: TripleEvent.Handler?
    ) async throws {

        do { try await swiftPM.cleanBuildArtifacts(in: storage, using: environment, onEvent: onEvent) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftPMError { throw error.tripleError }
        catch { throw TripleError.buildArtifactCleanupFailed("An unexpected cleanup error occurred.") }
    }

    private func resetBuildStorageUnderLease(
        in storage: SwiftPMScratchStorage,
        using environment: LocalBuildEnvironment,
        onEvent: TripleEvent.Handler?
    ) async throws {

        do { try await swiftPM.resetBuildStorage(in: storage, using: environment, onEvent: onEvent) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SwiftPMError { throw error.tripleError }
        catch { throw TripleError.buildStorageResetFailed("An unexpected cleanup error occurred.") }
    }

}
