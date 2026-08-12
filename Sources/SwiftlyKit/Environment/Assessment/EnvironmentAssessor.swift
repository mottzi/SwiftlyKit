import Foundation

/// Read-only orchestration that resolves one exact build environment.
struct EnvironmentAssessor {

    private(set) var assessHost: @Sendable () async throws -> HostReadiness = {
        try await HostPreflight().assess()
    }

    private(set) var detectSwiftly: @Sendable () async throws -> SwiftlyInstallation? = {
        try await SwiftlyInstallation.detect()
    }

    private(set) var loadReleases: @Sendable () async throws -> [OfficialStableRelease] = {
        try await SwiftOrgReleaseCatalog().stableReleases()
    }

    private(set) var inspectInventory: @Sendable (SwiftlyInstallation) async throws -> InstalledEnvironmentInventory = {
        try await InstalledEnvironmentInspector().inspectAll(swiftly: $0)
    }

    private(set) var locateSDK: @Sendable (String) -> URL? = {
        SDKBundleLocator.locate(identifier: $0)
    }

    func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection
    ) async throws -> EnvironmentAssessment {

        let observation = try await observe(packageRoot, for: target)
        return try assessment(selecting: toolchain, from: observation)
    }

    /// Captures one observation and returns each exact compatible environment in newest-first order.
    func compatibleEnvironments(_ packageRoot: URL, for target: BuildTarget) async throws -> EnvironmentChoices {

        let observation = try await observe(packageRoot, for: target)
        let releases = EnvironmentSelectionPolicy.compatibleReleases(
            toolsVersion: observation.packageInputs.toolsVersion,
            architecture: target.architecture,
            releases: observation.releases
        )
        let assessments = releases.map { release in
            assessment(for: release, from: observation)
        }

        return EnvironmentChoices(
            assessments: assessments,
            toolsVersion: observation.packageInputs.toolsVersion,
            swiftVersionPreference: observation.packageInputs.swiftVersion,
            architecture: target.architecture,
            releases: observation.releases,
            inventory: observation.inventory
        )
    }

}

extension EnvironmentAssessor {

    private func observe(_ packageRoot: URL, for target: BuildTarget) async throws -> Observation {

        try (await assessHost()).requireReady()

        let packageInputs = try PackageInputSnapshot.capture(at: packageRoot)
        let swiftly = try await detectSwiftly()
        let releases = try await officialReleases()
        let inventory = try await installedInventory(swiftly)

        return Observation(
            packageInputs: packageInputs,
            releases: releases,
            inventory: inventory,
            isSwiftlyAvailable: swiftly != nil,
            target: target
        )
    }

    private func assessment(
        selecting toolchain: ToolchainSelection,
        from observation: Observation
    ) throws -> EnvironmentAssessment {

        let release: OfficialStableRelease

        do {
            release = try EnvironmentSelectionPolicy.select(
                toolchain: toolchain,
                toolsVersion: observation.packageInputs.toolsVersion,
                swiftVersionPreference: observation.packageInputs.swiftVersion,
                architecture: observation.target.architecture,
                releases: observation.releases,
                inventory: observation.inventory
            )
        } catch {
            throw error.swiftlyKitError
        }

        return assessment(for: release, from: observation)
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
            target: observation.target
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
            throw SwiftlyKitError.networkFailure("The Swift.org release catalog is unavailable.")
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

    /// Package, catalog, and installed state captured by one read-only observation.
    private struct Observation {
        let packageInputs: PackageInputSnapshot
        let releases: [OfficialStableRelease]
        let inventory: InstalledEnvironmentInventory
        let isSwiftlyAvailable: Bool
        let target: BuildTarget
    }

}
