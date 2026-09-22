import Foundation

/// Read-only orchestration that resolves one exact build environment.
struct EnvironmentAssessor: Sendable {

    typealias LocalEnvironmentLoadHandler = @Sendable (
        _ packageRoot: URL,
        _ environmentStorage: EnvironmentStorage
    ) async throws -> LocalEnvironmentSnapshot

    typealias ReleaseCatalogLoadHandler = @Sendable () async throws -> AssessmentCatalogSnapshot

    private let environmentStorage: EnvironmentStorage
    private let loadLocalEnvironment: LocalEnvironmentLoadHandler
    private let loadReleaseCatalog: ReleaseCatalogLoadHandler

    init(environmentStorage: EnvironmentStorage = .standard) {
        self.init(
            environmentStorage: environmentStorage,
            loadLocalEnvironment: Self.loadLocalEnvironment,
            loadReleaseCatalog: Self.loadOfficialReleaseCatalog
        )
    }

    init(
        environmentStorage: EnvironmentStorage,
        loadLocalEnvironment: @escaping LocalEnvironmentLoadHandler,
        loadReleaseCatalog: @escaping ReleaseCatalogLoadHandler
    ) {
        self.environmentStorage = environmentStorage
        self.loadLocalEnvironment = loadLocalEnvironment
        self.loadReleaseCatalog = loadReleaseCatalog
    }

    /// Selects one environment from a shared discovery observation.
    func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection
    ) async throws -> EnvironmentAssessment {

        let choices = try await compatibleEnvironments(packageRoot, for: target)
        return try choices.select(toolchain)
    }

    /// Captures one observation and returns each exact compatible environment in newest-first order.
    func compatibleEnvironments(_ packageRoot: URL, for target: BuildTarget) async throws -> EnvironmentChoices {

        let local = try await loadLocalEnvironment(packageRoot, environmentStorage)
        let catalog = try await loadReleaseCatalog()
        let releases = EnvironmentSelectionPolicy.compatibleReleases(
            toolsVersion: local.packageInputs.toolsVersion,
            architecture: target.architecture,
            releases: catalog.releases
        )
        var assessments = releases.map { release in
            assessment(for: release, target: target, from: local)
        }

        if catalog.provenance == .cache {
            assessments.removeAll { $0.requiresInstallation }
            guard !assessments.isEmpty else { throw AssessmentCatalogFailure.unavailable }
        }

        return EnvironmentChoices(
            assessments: assessments,
            toolsVersion: local.packageInputs.toolsVersion,
            swiftVersionPreference: local.packageInputs.swiftVersion,
            architecture: target.architecture,
            releases: catalog.provenance == .cache ? assessments.map(\.release) : catalog.releases,
            inventory: local.inventory,
            usesCachedCatalog: catalog.provenance == .cache
        )
    }

}

extension EnvironmentAssessor {

    private func assessment(
        for release: OfficialStableRelease,
        target: BuildTarget,
        from local: LocalEnvironmentSnapshot
    ) -> EnvironmentAssessment {

        EnvironmentAssessment(
            packageInputs: local.packageInputs,
            release: release,
            requiredComponents: local.requiredComponents(for: release),
            target: target,
            environmentStorage: local.environmentStorage
        )
    }

}

extension EnvironmentAssessor {

    private static func loadLocalEnvironment(
        packageRoot: URL,
        environmentStorage: EnvironmentStorage
    ) async throws -> LocalEnvironmentSnapshot {

        let readiness = try await HostPreflight().assess()
        try readiness.requireReady()

        let packageInputs = try PackageInputSnapshot.capture(at: packageRoot)
        let validatedStorage = try environmentStorage.validated(
            against: packageInputs.packageRoot
        )
        let swiftly = try await SwiftlyInstallation.detect(storage: validatedStorage)

        let inventory: InstalledEnvironmentInventory
        if let swiftly {
            do {
                inventory = try await InstalledEnvironmentInspector().inspectAll(swiftly: swiftly)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SwiftlyKitError.incompatibleSwiftly
            }
        } else {
            inventory = InstalledEnvironmentInventory(toolchains: [], sdks: [])
        }

        return LocalEnvironmentSnapshot(
            packageInputs: packageInputs,
            environmentStorage: validatedStorage,
            inventory: inventory,
            isSwiftlyAvailable: swiftly != nil,
            sdkBundleExists: { identifier in
                SDKBundleLocator.locate(identifier: identifier, in: validatedStorage) != nil
            }
        )
    }

    private static func loadOfficialReleaseCatalog() async throws -> AssessmentCatalogSnapshot {

        do {
            return AssessmentCatalogSnapshot(
                releases: try await SwiftOrgReleaseCatalog.shared.stableReleases(),
                provenance: .current
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch SwiftOrgReleaseCatalog.CatalogError.invalidPayload {
            throw SwiftlyKitError.integrityCheckFailed("Swift.org returned unsupported release metadata.")
        } catch {
            guard let releases = await SwiftOrgReleaseCatalog.shared.cachedReleases()
            else { throw AssessmentCatalogFailure.unavailable }
            return AssessmentCatalogSnapshot(releases: releases, provenance: .cache)
        }
    }

}

/// Package and installed state captured before release selection begins.
struct LocalEnvironmentSnapshot: Sendable {

    let packageInputs: PackageInputSnapshot
    let environmentStorage: EnvironmentStorage
    let inventory: InstalledEnvironmentInventory
    let isSwiftlyAvailable: Bool
    let sdkBundleExists: @Sendable (String) -> Bool

    /// Returns the installations required by the observed inventory and SDK bundle location.
    func requiredComponents(for release: OfficialStableRelease) -> [PreparationComponent] {

        let toolchainAvailable = inventory.contains(toolchain: release.version)
        let sdkListed = inventory.contains(
            toolchain: release.version,
            sdk: release.staticLinuxSDK.identifier
        )
        let sdkBundleAvailable = sdkBundleExists(release.staticLinuxSDK.identifier)
        let sdkAvailable = sdkBundleAvailable && (sdkListed || !toolchainAvailable)

        var components: [PreparationComponent] = []
        if !isSwiftlyAvailable { components.append(.swiftly) }
        if isSwiftlyAvailable && !toolchainAvailable { components.append(.swiftlyUpdate) }
        if !toolchainAvailable { components.append(.toolchain) }
        if !sdkAvailable { components.append(.staticLinuxSDK) }

        return components
    }

}

/// Current or fallback origin of an assessment catalog observation.
enum AssessmentCatalogProvenance: Equatable, Sendable {
    case current
    case cache
}

/// Validated release metadata and its source for one environment observation.
struct AssessmentCatalogSnapshot: Sendable {
    let releases: [OfficialStableRelease]
    let provenance: AssessmentCatalogProvenance
}

enum AssessmentCatalogFailure {

    static let unavailable = SwiftlyKitError.networkFailure(
        "The Swift.org release catalog is unavailable."
    )

}
