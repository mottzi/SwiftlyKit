import Foundation

/// Read-only orchestration that resolves one exact build environment.
struct EnvironmentAssessor: Sendable {

    private let environmentStorage: EnvironmentStorage
    private let loadLocalEnvironment: LocalEnvironmentLoadHandler
    private let loadReleaseCatalog: ReleaseCatalogLoadHandler

    typealias LocalEnvironmentLoadHandler = @Sendable (
        _ packageRoot: URL,
        _ environmentStorage: EnvironmentStorage
    ) async throws -> LocalEnvironmentSnapshot

    typealias ReleaseCatalogLoadHandler = @Sendable (
        _ requirement: AssessmentCatalogRequirement
    ) async throws -> AssessmentCatalogSnapshot

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

    func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection
    ) async throws -> EnvironmentAssessment {

        let local = try await loadLocalEnvironment(packageRoot, environmentStorage)
        let catalog = try await loadReleaseCatalog(.currentOrCached)

        switch catalog.provenance {
            case .current:
                return try assessment(
                    selecting: toolchain,
                    releases: catalog.releases,
                    target: target,
                    from: local
                )
            case .cache:
                return try cachedAssessment(
                    selecting: toolchain,
                    releases: catalog.releases,
                    target: target,
                    from: local
                )
        }
    }

    /// Captures one observation and returns each exact compatible environment in newest-first order.
    func compatibleEnvironments(
        _ packageRoot: URL,
        for target: BuildTarget
    ) async throws -> EnvironmentChoices {

        let local = try await loadLocalEnvironment(packageRoot, environmentStorage)
        let catalog = try await loadReleaseCatalog(.currentOnly)
        guard catalog.provenance == .current else {
            throw AssessmentCatalogFailure.unavailable
        }

        let releases = EnvironmentSelectionPolicy.compatibleReleases(
            toolsVersion: local.packageInputs.toolsVersion,
            architecture: target.architecture,
            releases: catalog.releases
        )
        let assessments = releases.map { release in
            assessment(for: release, target: target, from: local)
        }

        return EnvironmentChoices(
            assessments: assessments,
            toolsVersion: local.packageInputs.toolsVersion,
            swiftVersionPreference: local.packageInputs.swiftVersion,
            architecture: target.architecture,
            releases: catalog.releases,
            inventory: local.inventory
        )
    }

}

extension EnvironmentAssessor {

    private func assessment(
        selecting toolchain: ToolchainSelection,
        releases: [OfficialStableRelease],
        target: BuildTarget,
        from local: LocalEnvironmentSnapshot
    ) throws -> EnvironmentAssessment {

        let release: OfficialStableRelease

        do {
            release = try EnvironmentSelectionPolicy.select(
                toolchain: toolchain,
                toolsVersion: local.packageInputs.toolsVersion,
                swiftVersionPreference: local.packageInputs.swiftVersion,
                architecture: target.architecture,
                releases: releases,
                inventory: local.inventory
            )
        } catch {
            throw error.swiftlyKitError
        }

        return assessment(for: release, target: target, from: local)
    }

    private func cachedAssessment(
        selecting toolchain: ToolchainSelection,
        releases: [OfficialStableRelease],
        target: BuildTarget,
        from local: LocalEnvironmentSnapshot
    ) throws -> EnvironmentAssessment {

        let installedReleases = releases.filter(
            local.containsCompletePair(for:)
        )

        let cached: EnvironmentAssessment
        do {
            cached = try assessment(
                selecting: toolchain,
                releases: installedReleases,
                target: target,
                from: local
            )
        } catch {
            throw AssessmentCatalogFailure.unavailable
        }

        guard cached.requiredComponents.isEmpty else {
            throw AssessmentCatalogFailure.unavailable
        }
        return cached
    }

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

        try (await HostPreflight().assess()).requireReady()

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

    private static func loadOfficialReleaseCatalog(
        requiring requirement: AssessmentCatalogRequirement
    ) async throws -> AssessmentCatalogSnapshot {

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
            guard case .currentOrCached = requirement,
                  let releases = await SwiftOrgReleaseCatalog.shared.cachedReleases()
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
        if !toolchainAvailable { components.append(.toolchain) }
        if !sdkAvailable { components.append(.staticLinuxSDK) }

        return components
    }

    func containsCompletePair(for release: OfficialStableRelease) -> Bool {

        inventory.contains(
            toolchain: release.version,
            sdk: release.staticLinuxSDK.identifier
        ) && sdkBundleExists(release.staticLinuxSDK.identifier)
    }

}

enum AssessmentCatalogRequirement: Equatable, Sendable {
    case currentOnly
    case currentOrCached
}

enum AssessmentCatalogProvenance: Equatable, Sendable {
    case current
    case cache
}

struct AssessmentCatalogSnapshot: Sendable {
    let releases: [OfficialStableRelease]
    let provenance: AssessmentCatalogProvenance
}

enum AssessmentCatalogFailure {

    static let unavailable = SwiftlyKitError.networkFailure(
        "The Swift.org release catalog is unavailable."
    )

}
