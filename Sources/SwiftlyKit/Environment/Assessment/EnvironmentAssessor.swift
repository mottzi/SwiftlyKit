import Foundation

/// Read-only orchestration that resolves one exact build environment.
struct EnvironmentAssessor {

    private(set) var environmentStorage: EnvironmentStorage
    private(set) var assessHost: @Sendable () async throws -> HostReadiness
    private(set) var detectSwiftly: @Sendable () async throws -> SwiftlyInstallation?
    private(set) var loadReleases: @Sendable () async throws -> [OfficialStableRelease]
    private(set) var loadCachedReleases: @Sendable () async -> [OfficialStableRelease]?
    private(set) var inspectInventory: @Sendable (SwiftlyInstallation) async throws -> InstalledEnvironmentInventory
    private(set) var locateSDK: @Sendable (String) -> URL?

    init(
        environmentStorage: EnvironmentStorage = .standard,
        assessHost: @escaping @Sendable () async throws -> HostReadiness = {
            try await HostPreflight().assess()
        },
        detectSwiftly: (@Sendable () async throws -> SwiftlyInstallation?)? = nil,
        loadReleases: @escaping @Sendable () async throws -> [OfficialStableRelease] = {
            try await SwiftOrgReleaseCatalog.shared.stableReleases()
        },
        loadCachedReleases: @escaping @Sendable () async -> [OfficialStableRelease]? = {
            await SwiftOrgReleaseCatalog.shared.cachedReleases()
        },
        inspectInventory: @escaping @Sendable (SwiftlyInstallation) async throws -> InstalledEnvironmentInventory = {
            try await InstalledEnvironmentInspector().inspectAll(swiftly: $0)
        },
        locateSDK: (@Sendable (String) -> URL?)? = nil
    ) {
        self.environmentStorage = environmentStorage
        self.assessHost = assessHost
        if let detectSwiftly {
            self.detectSwiftly = detectSwiftly
        } else {
            self.detectSwiftly = {
                try await SwiftlyInstallation.detect(storage: environmentStorage)
            }
        }
        self.loadReleases = loadReleases
        self.loadCachedReleases = loadCachedReleases
        self.inspectInventory = inspectInventory
        self.locateSDK = locateSDK ?? { identifier in
            SDKBundleLocator.locate(identifier: identifier, in: environmentStorage)
        }
    }

    func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection
    ) async throws -> EnvironmentAssessment {

        let observation = try await observe(packageRoot, for: target)

        do {
            let releases = try await officialReleases()
            return try assessment(
                selecting: toolchain,
                releases: releases,
                from: observation
            )
        } catch SwiftlyKitError.networkFailure {
            return try await cachedAssessment(
                selecting: toolchain,
                from: observation
            )
        }
    }

    /// Captures one observation and returns each exact compatible environment in newest-first order.
    func compatibleEnvironments(_ packageRoot: URL, for target: BuildTarget) async throws -> EnvironmentChoices {

        let observation = try await observe(packageRoot, for: target)
        let observedReleases = try await officialReleases()
        let releases = EnvironmentSelectionPolicy.compatibleReleases(
            toolsVersion: observation.packageInputs.toolsVersion,
            architecture: target.architecture,
            releases: observedReleases
        )
        let assessments = releases.map { release in
            assessment(for: release, from: observation)
        }

        return EnvironmentChoices(
            assessments: assessments,
            toolsVersion: observation.packageInputs.toolsVersion,
            swiftVersionPreference: observation.packageInputs.swiftVersion,
            architecture: target.architecture,
            releases: observedReleases,
            inventory: observation.inventory
        )
    }

}

extension EnvironmentAssessor {

    private func observe(_ packageRoot: URL, for target: BuildTarget) async throws -> Observation {

        try (await assessHost()).requireReady()

        let packageInputs = try PackageInputSnapshot.capture(at: packageRoot)
        let validatedStorage = try environmentStorage.validated(against: packageInputs.packageRoot)
        let swiftly = try await detectSwiftly()
        let inventory = try await installedInventory(swiftly)

        return Observation(
            packageInputs: packageInputs,
            inventory: inventory,
            isSwiftlyAvailable: swiftly != nil,
            target: target,
            environmentStorage: validatedStorage
        )
    }

    private func assessment(
        selecting toolchain: ToolchainSelection,
        releases: [OfficialStableRelease],
        from observation: Observation
    ) throws -> EnvironmentAssessment {

        let release: OfficialStableRelease

        do {
            release = try EnvironmentSelectionPolicy.select(
                toolchain: toolchain,
                toolsVersion: observation.packageInputs.toolsVersion,
                swiftVersionPreference: observation.packageInputs.swiftVersion,
                architecture: observation.target.architecture,
                releases: releases,
                inventory: observation.inventory
            )
        } catch {
            throw error.swiftlyKitError
        }

        return assessment(for: release, from: observation)
    }

    private func cachedAssessment(
        selecting toolchain: ToolchainSelection,
        from observation: Observation
    ) async throws -> EnvironmentAssessment {

        guard let releases = await loadCachedReleases() else { throw Self.catalogUnavailable }

        let installedReleases = releases.filter { release in
            guard observation.inventory.contains(
                toolchain: release.version,
                sdk: release.staticLinuxSDK.identifier
            ) else { return false }

            return locateSDK(release.staticLinuxSDK.identifier) != nil
        }

        let cachedAssessment: EnvironmentAssessment
        do {
            cachedAssessment = try assessment(
                selecting: toolchain,
                releases: installedReleases,
                from: observation
            )
        } catch {
            throw Self.catalogUnavailable
        }

        guard cachedAssessment.requiredComponents.isEmpty else { throw Self.catalogUnavailable }

        return cachedAssessment
    }

    private func assessment(for release: OfficialStableRelease, from observation: Observation) -> EnvironmentAssessment {

        let toolchainAvailable = observation.inventory.contains(toolchain: release.version)
        let sdkListed = observation.inventory.contains(toolchain: release.version, sdk: release.staticLinuxSDK.identifier)
        let sdkBundleURL = locateSDK(release.staticLinuxSDK.identifier)

        let sdkAvailable = sdkBundleURL != nil && (sdkListed || !toolchainAvailable)

        var requiredComponents: [PreparationComponent] = []
        if !observation.isSwiftlyAvailable { requiredComponents.append(.swiftly) }
        if !toolchainAvailable { requiredComponents.append(.toolchain) }
        if !sdkAvailable { requiredComponents.append(.staticLinuxSDK) }

        return EnvironmentAssessment(
            packageInputs: observation.packageInputs,
            release: release,
            requiredComponents: requiredComponents,
            target: observation.target,
            environmentStorage: observation.environmentStorage
        )
    }

}

extension EnvironmentAssessor {

    private func officialReleases() async throws -> [OfficialStableRelease] {

        do {
            return try await loadReleases()
        } catch is CancellationError {
            throw CancellationError()
        } catch SwiftOrgReleaseCatalog.CatalogError.invalidPayload {
            throw SwiftlyKitError.integrityCheckFailed("Swift.org returned unsupported release metadata.")
        } catch {
            throw Self.catalogUnavailable
        }
    }

    private func installedInventory(_ swiftly: SwiftlyInstallation?) async throws -> InstalledEnvironmentInventory {

        guard let swiftly else { return InstalledEnvironmentInventory(toolchains: [], sdks: []) }

        do { return try await inspectInventory(swiftly) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SwiftlyKitError.incompatibleSwiftly }
    }

}

extension EnvironmentAssessor {

    /// Package and installed state captured by one read-only observation.
    private struct Observation {
        let packageInputs: PackageInputSnapshot
        let inventory: InstalledEnvironmentInventory
        let isSwiftlyAvailable: Bool
        let target: BuildTarget
        let environmentStorage: EnvironmentStorage
    }

    private static let catalogUnavailable = SwiftlyKitError.networkFailure(
        "The Swift.org release catalog is unavailable."
    )

}
