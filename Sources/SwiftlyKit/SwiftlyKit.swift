import Foundation

/// Prepares official Swift cross-compilation environments and builds Linux executables.
///
/// Assessing is read-only. Passing the returned assessment to ``prepare(_:onEvent:)``
/// explicitly authorizes its required installations. The resulting
/// ``LocalBuildEnvironment`` carries the package, target, toolchain, and SDK context
/// used by every later operation.
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
        self.mutationGate = MutationGate()
        self.assessor = EnvironmentAssessor()
        self.preparer = EnvironmentPreparer()
        self.swiftPM = SwiftPM()
    }
    
    init(
        mutationGate: MutationGate = MutationGate(),
        assessor: EnvironmentAssessor,
        preparer: EnvironmentPreparer,
        swiftPM: SwiftPM
    ) {
        self.mutationGate = mutationGate
        self.assessor = assessor
        self.preparer = preparer
        self.swiftPM = swiftPM
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
            do {
                return try await preparer.prepare(assessment, onEvent: onEvent)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SwiftlyKitError {
                throw error
            } catch let error as EnvironmentPreparationError {
                throw error.swiftlyKitError
            } catch let error as InstalledEnvironmentError {
                throw error.swiftlyKitError
            } catch {
                throw SwiftlyKitError.swiftlyInstallationFailed(
                    "An unexpected environment error occurred."
                )
            }
        }
    }
    
    /// Discovers executable products in the package bound to a prepared environment.
    public func executableProducts(
        using environment: LocalBuildEnvironment
    ) async throws -> [ExecutableProduct] {
        do {
            return try await swiftPM.executableProducts(using: environment)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SwiftlyKitError {
            throw error
        } catch let error as SwiftPMError {
            throw error.swiftlyKitError
        } catch {
            throw SwiftlyKitError.packageInspectionFailed("An unexpected package error occurred.")
        }
    }
    
    /// Explicitly resolves dependencies in the package bound to a prepared environment.
    public func resolveDependencies(
        using environment: LocalBuildEnvironment,
        onEvent: EventHandler? = nil
    ) async throws {
        try await mutationGate.withAccess {
            do {
                try await swiftPM.resolveDependencies(
                    using: environment,
                    onEvent: onEvent
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SwiftlyKitError {
                throw error
            } catch let error as SwiftPMError {
                throw error.swiftlyKitError
            } catch {
                throw SwiftlyKitError.dependencyResolutionFailed(
                    "An unexpected dependency resolution error occurred."
                )
            }
        }
    }
    
    /// Builds, verifies, and optionally publishes one executable product.
    public func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: EventHandler? = nil
    ) async throws -> URL {
        try await mutationGate.withAccess {
            guard !request.product.name.isEmpty else {
                throw SwiftlyKitError.executableProductNotFound(request.product.name)
            }
            do {
                return try await swiftPM.build(
                    request,
                    using: environment,
                    onEvent: onEvent
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SwiftlyKitError {
                throw error
            } catch let error as SwiftPMError {
                throw error.swiftlyKitError
            } catch {
                throw SwiftlyKitError.buildFailed("An unexpected build error occurred.")
            }
        }
    }
    
}
