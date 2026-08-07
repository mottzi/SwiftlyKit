import Foundation

/// Read-only orchestration that resolves one exact build environment.
struct EnvironmentAssessor: Sendable {
    
    let checkHost: @Sendable () async throws -> Void
    let detectSwiftly: @Sendable () async throws -> SwiftlyInstallation?
    let loadReleases: @Sendable () async throws -> [OfficialStableRelease]
    let inspectInventory: @Sendable (SwiftlyInstallation) async throws -> InstalledEnvironmentInventory
    let locateSDK: @Sendable (String) -> URL?
    
    init(
        checkHost: @escaping @Sendable () async throws -> Void = {
            _ = try await HostPreflight().check()
        },
        detectSwiftly: @escaping @Sendable () async throws -> SwiftlyInstallation? = {
            try await SwiftlyInstallation.detect()
        },
        loadReleases: @escaping @Sendable () async throws -> [OfficialStableRelease] = {
            try await SwiftOrgReleaseCatalog().stableReleases()
        },
        inspectInventory: @escaping @Sendable (SwiftlyInstallation) async throws -> InstalledEnvironmentInventory = {
            try await InstalledEnvironmentInspector().inspectAll(swiftly: $0)
        },
        locateSDK: @escaping @Sendable (String) -> URL? = {
            SDKBundleLocator.locate(identifier: $0)
        }
    ) {
        self.checkHost = checkHost
        self.detectSwiftly = detectSwiftly
        self.loadReleases = loadReleases
        self.inspectInventory = inspectInventory
        self.locateSDK = locateSDK
    }
    
}

extension EnvironmentAssessor {
    
    func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection
    ) async throws -> EnvironmentAssessment {
        
        try await checkHost()
        let requirements = try loadRequirements(at: packageRoot)
        let snapshot = try PackageInputSnapshot.capture(requirements)
        let swiftly = try await detectSwiftly()
        let releases = try await officialReleases()
        let inventory = try await installedInventory(swiftly)
        let release: OfficialStableRelease
        do {
            release = try EnvironmentSelectionPolicy.select(
                toolchain: toolchain,
                toolsVersion: requirements.toolsVersion,
                swiftVersionPreference: requirements.swiftVersion,
                architecture: target.architecture,
                releases: releases,
                installedToolchains: inventory.toolchains,
                installedSDKs: inventory.sdks
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EnvironmentSelectionPolicy.SelectionError {
            throw error.swiftlyKitError
        } catch {
            throw SwiftlyKitError.compatibleReleaseUnavailable
        }
        
        let toolchainAvailable = inventory.contains(toolchain: release.version)
        let sdkListed = inventory.contains(
            toolchain: release.version,
            sdk: release.staticLinuxSDK.identifier
        )
        let sdkBundleURL = locateSDK(release.staticLinuxSDK.identifier)
        let sdkAvailable = sdkBundleURL != nil && (sdkListed || !toolchainAvailable)
        var requiredComponents: [PreparationComponent] = []
        if swiftly == nil { requiredComponents.append(.swiftly) }
        if !toolchainAvailable { requiredComponents.append(.toolchain) }
        if !sdkAvailable { requiredComponents.append(.staticLinuxSDK) }
        
        return EnvironmentAssessment(
            packageInputs: snapshot,
            release: release,
            requiredComponents: requiredComponents,
            target: target
        )
    }
    
}

extension EnvironmentAssessor {
    
    private func loadRequirements(at packageRoot: URL) throws -> PackageRequirements {
        do {
            return try PackageRequirements.load(at: packageRoot)
        } catch let error as PackageRequirements.LoadingError {
            throw error.swiftlyKitError
        }
    }
    
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
    
    private func installedInventory(
        _ swiftly: SwiftlyInstallation?
    ) async throws -> InstalledEnvironmentInventory {
        guard let swiftly else {
            return InstalledEnvironmentInventory(toolchains: [], sdks: [])
        }
        do {
            return try await inspectInventory(swiftly)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SwiftlyKitError.incompatibleSwiftly
        }
    }
    
}
