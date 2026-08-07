import Foundation

/// Prepares official Swift cross-compilation environments and builds Linux executables.
public struct SwiftlyKit: Sendable {
    
    private let mutationGate: MutationGate
    private let buildRuntime: BuildRuntimeBackend
    
    public init() {
        self.mutationGate = MutationGate()
        self.buildRuntime = BuildRuntimeBackend()
    }
    
}

extension SwiftlyKit {
    
    /// Assesses the exact environment required by a trusted local package.
    public func assess(
        _ packageRoot: URL,
        for target: BuildTarget,
        toolchain: ToolchainSelection = .automatic
    ) async throws -> EnvironmentAssessment {
        
        _ = try await HostPreflight().check()
        let requirements = try loadRequirements(at: packageRoot)
        let snapshots = try inputSnapshots(for: requirements)
        let swiftly = try await SwiftlyInstallation.detect()
        let releases = try await loadReleases()
        let inventory = try await installedInventory(swiftly: swiftly)
        let architecture = target.architecture
        let selected: SelectedEnvironmentRelease
        do {
            selected = try EnvironmentSelectionPolicy.select(
                toolchain: toolchain,
                toolsVersion: requirements.toolsVersion,
                swiftVersionPreference: requirements.swiftVersion,
                architecture: architecture,
                releases: releases,
                installedToolchains: inventory.toolchains,
                installedSDKs: inventory.sdks
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw selectionError(error, toolsVersion: requirements.toolsVersion)
        }
        
        let release = selected.release
        let toolchainAvailable = inventory.toolchains.contains { $0.version == release.version }
        let sdkListed = inventory.sdks.contains {
            $0.toolchainVersion == release.version && $0.identifier == release.staticLinuxSDK.identifier
        }
        let locatedSDKBundle = SDKBundleLocator.locate(identifier: release.staticLinuxSDK.identifier)
        let sdkAvailable = locatedSDKBundle != nil && (sdkListed || !toolchainAvailable)
        let sdkBundleURL = sdkAvailable ? locatedSDKBundle : nil
        var requiredComponents: [PreparationComponent] = []
        if swiftly == nil { requiredComponents.append(.swiftly) }
        if !toolchainAvailable { requiredComponents.append(.toolchain) }
        if !sdkAvailable { requiredComponents.append(.staticLinuxSDK) }
        
        return EnvironmentAssessment(
            packageRoot: requirements.packageRoot,
            toolsVersion: requirements.toolsVersion,
            swiftVersion: release.version,
            staticLinuxSDK: StaticLinuxSDK(
                identifier: release.staticLinuxSDK.identifier,
                version: release.staticLinuxSDK.version
            ),
            isSwiftlyAvailable: swiftly != nil,
            isToolchainAvailable: toolchainAvailable,
            isStaticLinuxSDKAvailable: sdkAvailable,
            requiredComponents: requiredComponents,
            target: target,
            swiftVersionPreference: requirements.swiftVersion,
            swiftVersionFileURL: requirements.swiftVersionFileURL,
            swiftlyExecutableURL: swiftly?.executableURL,
            sdkDownloadURL: release.staticLinuxSDK.downloadURL,
            sdkChecksum: release.staticLinuxSDK.checksum,
            sdkBundleURL: sdkBundleURL,
            manifestContents: snapshots.manifest,
            swiftVersionFileContents: snapshots.swiftVersionFile
        )
    }
    
    /// Performs the exact mutations described by an accepted assessment.
    public func prepare(
        _ assessment: EnvironmentAssessment,
        onEvent: EventHandler? = nil
    ) async throws -> LocalBuildEnvironment {
        
        try await mutationGate.withAccess {
            try await prepareEnvironment(assessment, onEvent: onEvent)
        }
    }
    
    /// Discovers executable products using the exact prepared Swift toolchain.
    public func executableProducts(
        in packageRoot: URL,
        using environment: LocalBuildEnvironment
    ) async throws -> [ExecutableProduct] {
        
        let requirements = try loadRequirements(at: packageRoot)
        try validate(requirements, using: environment)
        do {
            return try await buildRuntime.executableProducts(
                in: requirements.packageRoot,
                using: runtimeEnvironment(environment)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw buildRuntimeError(error)
        }
    }
    
    /// Explicitly resolves package dependencies using the prepared toolchain.
    public func resolveDependencies(
        in packageRoot: URL,
        using environment: LocalBuildEnvironment,
        onEvent: EventHandler? = nil
    ) async throws {
        
        try await mutationGate.withAccess {
            let requirements = try loadRequirements(at: packageRoot)
            try validate(requirements, using: environment)
            await onEvent?(.progress(OperationProgress(
                operation: .resolvingDependencies,
                detail: "Resolving package dependencies."
            )))
            do {
                try await buildRuntime.resolveDependencies(
                    in: requirements.packageRoot,
                    using: runtimeEnvironment(environment),
                    onOutput: outputHandler(onEvent)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let mapped = buildRuntimeError(error)
                if case .buildFailed(let detail) = mapped {
                    throw SwiftlyKitError.dependencyResolutionFailed(detail)
                }
                throw mapped
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
            let requirements = try loadRequirements(at: request.packageRoot)
            try validate(requirements, using: environment)
            guard request.target == environment.target else { throw SwiftlyKitError.staticLinuxSDKUnavailable }
            guard !request.product.name.isEmpty else {
                throw SwiftlyKitError.executableProductNotFound(request.product.name)
            }
            await onEvent?(.progress(OperationProgress(
                operation: .building,
                detail: "Building \(request.product.name)."
            )))
            do {
                return try await buildRuntime.build(
                    request,
                    using: runtimeEnvironment(environment),
                    onOutput: outputHandler(onEvent)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw buildRuntimeError(error)
            }
        }
    }
    
}

extension SwiftlyKit {
    
    private struct InputSnapshots {
        let manifest: Data
        let swiftVersionFile: Data?
    }
    
    private struct InstalledInventory {
        let toolchains: [InstalledStableToolchain]
        let sdks: [InstalledStaticLinuxSDK]
    }
    
    private func loadRequirements(at packageRoot: URL) throws -> PackageRequirements {
        do {
            return try PackageRequirements.load(at: packageRoot)
        } catch let error as PackageRequirements.LoadingError {
            throw error.swiftlyKitError
        }
    }
    
    private func inputSnapshots(for requirements: PackageRequirements) throws -> InputSnapshots {
        do {
            let manifest = try Data(contentsOf: requirements.packageRoot.appending(path: "Package.swift"))
            let swiftVersionFile = try requirements.swiftVersionFileURL.map { try Data(contentsOf: $0) }
            return InputSnapshots(manifest: manifest, swiftVersionFile: swiftVersionFile)
        } catch {
            throw SwiftlyKitError.invalidPackageRoot(requirements.packageRoot)
        }
    }
    
    private func loadReleases() async throws -> [OfficialStableRelease] {
        do {
            return try await SwiftOrgReleaseCatalog().stableReleases()
        } catch is CancellationError {
            throw CancellationError()
        } catch SwiftOrgReleaseCatalog.CatalogError.invalidPayload {
            throw SwiftlyKitError.integrityCheckFailed("Swift.org returned unsupported release metadata.")
        } catch {
            throw SwiftlyKitError.networkFailure("The Swift.org release catalog is unavailable.")
        }
    }
    
    private func installedInventory(swiftly: SwiftlyInstallation?) async throws -> InstalledInventory {
        guard let swiftly else { return InstalledInventory(toolchains: [], sdks: []) }
        let inspector = InstalledEnvironmentInspector()
        let state: InstalledEnvironmentState
        do {
            state = try await inspector.inspect(swiftly: swiftly, selectedToolchain: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SwiftlyKitError.incompatibleSwiftly
        }
        let toolchains = state.toolchainVersions
            .map(InstalledStableToolchain.init(version:))
            .sorted { $0.version > $1.version }
        var sdks: [InstalledStaticLinuxSDK] = []
        for toolchain in toolchains {
            do {
                let state = try await inspector.inspect(swiftly: swiftly, selectedToolchain: toolchain.version)
                sdks += state.sdkIdentifiers.map {
                    InstalledStaticLinuxSDK(toolchainVersion: toolchain.version, identifier: $0)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return InstalledInventory(toolchains: toolchains, sdks: sdks)
    }
    
    private func prepareEnvironment(
        _ assessment: EnvironmentAssessment,
        onEvent: EventHandler?
    ) async throws -> LocalBuildEnvironment {
        
        _ = try await HostPreflight().check()
        try revalidate(assessment)
        let plan = EnvironmentPreparationPlan(
            toolchain: assessment.swiftVersion,
            sdk: StaticLinuxSDKInstallation(
                identifier: assessment.staticLinuxSDK.identifier,
                downloadURL: assessment.sdkDownloadURL,
                checksum: assessment.sdkChecksum
            ),
            requiresSwiftly: assessment.requiredComponents.contains(.swiftly),
            requiresToolchain: assessment.requiredComponents.contains(.toolchain),
            requiresSDK: assessment.requiredComponents.contains(.staticLinuxSDK)
        )
        let service = EnvironmentPreparationService(revalidate: { acceptedPlan in
            guard acceptedPlan == plan else { throw SwiftlyKitError.staleAssessment }
            try revalidate(assessment)
        })
        let swiftly: SwiftlyInstallation
        do {
            swiftly = try await service.prepare(plan) { component, detail in
                await onEvent?(.progress(OperationProgress(
                    operation: .preparingEnvironment,
                    component: component,
                    detail: detail
                )))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw environmentRuntimeError(error)
        }
        let state: InstalledEnvironmentState
        do {
            state = try await InstalledEnvironmentInspector().inspect(
                swiftly: swiftly,
                selectedToolchain: assessment.swiftVersion
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SwiftlyKitError.swiftlyInstallationFailed("The prepared environment could not be inspected.")
        }
        guard state.contains(
            toolchain: assessment.swiftVersion,
            sdkIdentifier: assessment.staticLinuxSDK.identifier
        ) else { throw SwiftlyKitError.staticLinuxSDKUnavailable }
        guard let sdkBundleURL = SDKBundleLocator.locate(identifier: assessment.staticLinuxSDK.identifier) else {
            throw SwiftlyKitError.staticLinuxSDKUnavailable
        }
        return LocalBuildEnvironment(
            swiftVersion: assessment.swiftVersion,
            staticLinuxSDK: assessment.staticLinuxSDK,
            swiftlyExecutableURL: swiftly.executableURL,
            sdkBundleURL: sdkBundleURL,
            target: assessment.target,
            toolsVersion: assessment.toolsVersion
        )
    }
    
    private func revalidate(_ assessment: EnvironmentAssessment) throws {
        let requirements: PackageRequirements
        do {
            requirements = try PackageRequirements.load(at: assessment.packageRoot)
        } catch {
            throw SwiftlyKitError.staleAssessment
        }
        guard requirements.packageRoot == assessment.packageRoot else { throw SwiftlyKitError.staleAssessment }
        guard requirements.toolsVersion == assessment.toolsVersion else { throw SwiftlyKitError.staleAssessment }
        guard requirements.swiftVersion == assessment.swiftVersionPreference else { throw SwiftlyKitError.staleAssessment }
        guard requirements.swiftVersionFileURL == assessment.swiftVersionFileURL else { throw SwiftlyKitError.staleAssessment }
        let snapshots: InputSnapshots
        do {
            snapshots = try inputSnapshots(for: requirements)
        } catch {
            throw SwiftlyKitError.staleAssessment
        }
        guard snapshots.manifest == assessment.manifestContents else { throw SwiftlyKitError.staleAssessment }
        guard snapshots.swiftVersionFile == assessment.swiftVersionFileContents else { throw SwiftlyKitError.staleAssessment }
    }
    
    private func validate(
        _ requirements: PackageRequirements,
        using environment: LocalBuildEnvironment
    ) throws {
        guard requirements.toolsVersion <= environment.swiftVersion else {
            throw SwiftlyKitError.unsupportedToolsVersion(requirements.toolsVersion)
        }
        guard FileManager.default.isExecutableFile(atPath: environment.swiftlyExecutableURL.path) else {
            throw SwiftlyKitError.incompatibleSwiftly
        }
        guard SDKBundleLocator.locate(identifier: environment.staticLinuxSDK.identifier) == environment.sdkBundleURL else {
            throw SwiftlyKitError.staticLinuxSDKUnavailable
        }
    }
    
    private func runtimeEnvironment(_ environment: LocalBuildEnvironment) -> BuildRuntimeEnvironment {
        BuildRuntimeEnvironment(
            swiftlyExecutable: environment.swiftlyExecutableURL,
            toolchainSelector: environment.swiftVersion.description,
            sdkID: environment.target.architecture.swiftSDKSelector,
            sdkArtifactBundle: environment.sdkBundleURL,
            architecture: environment.target.architecture
        )
    }
    
    private func outputHandler(_ handler: EventHandler?) -> BuildRuntimeOutputHandler? {
        guard let handler else { return nil }
        return { stream, text in
            let publicStream: CommandOutput.Stream = switch stream {
                case .standardOutput: .standardOutput
                case .standardError: .standardError
            }
            await handler(.output(CommandOutput(stream: publicStream, text: text)))
        }
    }
    
}

extension SwiftlyKit {
    
    private func selectionError(_ error: Error, toolsVersion: SwiftVersion) -> SwiftlyKitError {
        guard let error = error as? EnvironmentSelectionPolicy.SelectionError else {
            return .compatibleReleaseUnavailable
        }
        return switch error {
            case .incompatibleToolsVersion: .unsupportedToolsVersion(toolsVersion)
            case .invalidSwiftVersionPreference: .compatibleReleaseUnavailable
            case .unavailableRelease: .compatibleReleaseUnavailable
            case .unsupportedArchitecture: .staticLinuxSDKUnavailable
            case .noCompatibleRelease: .compatibleReleaseUnavailable
        }
    }
    
    private func environmentRuntimeError(_ error: Error) -> SwiftlyKitError {
        guard let error = error as? EnvironmentRuntimeError else {
            return .swiftlyInstallationFailed("An unexpected environment error occurred.")
        }
        return switch error {
            case .invalidDownloadURL: .integrityCheckFailed("An official download URL was invalid.")
            case .invalidHTTPResponse(let status): .networkFailure("Swift.org returned HTTP \(status).")
            case .downloadFailed: .networkFailure("The official Swiftly package could not be downloaded.")
            case .packageSignatureRejected: .integrityCheckFailed("The Swiftly installer signature or Apple trust check failed.")
            case .installationFailed(let detail): .swiftlyInstallationFailed(detail)
            case .inspectionFailed(let detail): .swiftlyInstallationFailed(detail)
            case .invalidInspectionOutput: .incompatibleSwiftly
            case .commandCouldNotRun(let url): .swiftlyInstallationFailed("Could not run \(url.lastPathComponent).")
            case .swiftlyUnavailableAfterInstallation: .swiftlyInstallationFailed("Swiftly was unavailable after installation.")
            case .unauthorizedMutationRequired: .staleAssessment
        }
    }
    
    private func buildRuntimeError(_ error: Error) -> SwiftlyKitError {
        guard let error = error as? BuildRuntimeError else {
            return .buildFailed("An unexpected build error occurred.")
        }
        return switch error {
            case .invalidEnvironment: .staticLinuxSDKUnavailable
            case .commandFailed(let operation, let diagnostic):
                if operation == "dependency resolution" { .dependencyResolutionFailed(diagnostic) }
                else if operation == "package description" { .packageInspectionFailed(diagnostic) }
                else if operation == "stripping" { .stripFailed(diagnostic) }
                else { .buildFailed(diagnostic) }
            case .malformedPackageDescription: .packageInspectionFailed("SwiftPM returned malformed package metadata.")
            case .dependencyResolutionRequired: .dependencyResolutionRequired
            case .executableNotFound(let product): .executableProductNotFound(product)
            case .unsupportedProductResources(let product): .unsupportedProductResources(product)
            case .invalidExecutable(let detail): .executableVerificationFailed(detail)
            case .outputAlreadyExists(let url): .outputAlreadyExists(url)
            case .outputPublicationFailed(let url): .outputPublicationFailed(url)
        }
    }
    
}

private extension BuildTarget {
    
    var architecture: LinuxArchitecture {
        switch self {
            case .linux(let architecture): architecture
        }
    }
    
}
