import Foundation

/// Prepares exactly the environment authorized by an accepted assessment.
struct EnvironmentPreparer {

    private(set) var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    private(set) var temporaryDirectory: URL = FileManager.default.temporaryDirectory
    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()

    private(set) var assessHost: @Sendable () async throws -> HostReadiness = {
        try await HostPreflight().assess()
    }

    private(set) var downloadPackage: @Sendable (URL, URL) async throws -> Void = {
        try await HTTPPackageDownloader().download(from: $0, to: $1)
    }

    private(set) var detectSwiftly: @Sendable () async throws -> SwiftlyInstallation? = {
        try await SwiftlyInstallation.detect()
    }

    private(set) var inspect: @Sendable (SwiftlyInstallation, SwiftVersion) async throws -> InstalledEnvironmentInventory
    = { swiftly, toolchain in
        try await InstalledEnvironmentInspector().inspect(
            swiftly: swiftly,
            selectedToolchain: toolchain
        )
    }

    private(set) var locateSDK: @Sendable (String) -> URL? = {
        SDKBundleLocator.locate(identifier: $0)
    }

    private(set) var revalidate: @Sendable (EnvironmentAssessment) async throws -> Void = {
        try $0.packageInputs.validateCurrent()
    }

    /// Prepares the environment authorized by one accepted assessment.
    func prepare(
        _ assessment: EnvironmentAssessment,
        swiftPMEnvironment: SwiftPMEnvironment.Snapshot = SwiftPMEnvironment.inherited.snapshot(),
        swiftPMTraits: SwiftPMTraits = .packageDefaults,
        swiftPMSharedStorage: SwiftPMSharedStorage = .standard,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder? = nil,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> LocalBuildEnvironment {

        let sharedStorage = try swiftPMSharedStorage.validated()

        do {
            try (await assessHost()).requireReady()
            try await revalidate(assessment)
            try Task.checkCancellation()

            let prepared = try await installRequiredComponents(
                assessment,
                recordRemovalPlan: recordRemovalPlan,
                onEvent: onEvent
            )

            guard prepared.inventory.contains(
                toolchain: assessment.swiftVersion,
                sdk: assessment.staticLinuxSDK.identifier
            ) else {
                throw SwiftlyKitError.staleAssessment
            }

            guard let sdkBundleURL = locateSDK(assessment.staticLinuxSDK.identifier) else {
                throw SwiftlyKitError.staleAssessment
            }

            return LocalBuildEnvironment(
                swiftVersion: assessment.swiftVersion,
                staticLinuxSDK: assessment.staticLinuxSDK,
                packageRoot: assessment.packageRoot,
                swiftly: prepared.swiftly,
                sdkBundleURL: sdkBundleURL,
                target: assessment.target,
                swiftPMEnvironment: swiftPMEnvironment,
                swiftPMTraits: swiftPMTraits,
                swiftPMSharedStorage: sharedStorage
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EnvironmentPlanRecordingError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

}

extension EnvironmentPreparer {

    private func installRequiredComponents(
        _ assessment: EnvironmentAssessment,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder?,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> InstalledComponents {

        do {
            var swiftly = try await detectSwiftly()
        
            if swiftly == nil {
                guard assessment.requiredComponents.contains(.swiftly)
                else { throw EnvironmentPreparationError.swiftlyUnavailableAfterInstallation }
            
                try await bootstrapSwiftly(onEvent: onEvent)
                swiftly = try await detectSwiftly()
            }
        
            guard let swiftly else { throw EnvironmentPreparationError.swiftlyUnavailableAfterInstallation }

            let toolchain = assessment.swiftVersion
            let sdk = assessment.release.staticLinuxSDK
            let sdkMetadata = assessment.release.staticLinuxSDKMetadata

            var state = try await inspect(swiftly, toolchain)
            var installedToolchain = false

            if !state.contains(toolchain: toolchain) {
                guard assessment.requiredComponents.contains(.toolchain)
                else { throw EnvironmentPreparationError.unauthorizedMutationRequired }

                await report(
                    .toolchain,
                    "Installing Swift \(toolchain) without changing the selected default.",
                    to: onEvent
                )

                let installToolchainCommand = SubprocessCommand(
                    executableURL: swiftly.executableURL,
                    arguments: ["install", toolchain.description, "--verify", "--assume-yes"],
                    workingDirectory: temporaryDirectory
                )

                try await record(.toolchain(toolchain), using: recordRemovalPlan)
                try await checkedRun(installToolchainCommand, onEvent: onEvent)
                installedToolchain = true

                state = try await inspect(swiftly, toolchain)

                guard state.contains(toolchain: toolchain) else {
                    throw EnvironmentPreparationError.installationFailed(
                        "Swiftly did not report the selected toolchain after installation."
                    )
                }
            }

            if !state.contains(toolchain: toolchain, sdk: sdk.identifier) {
                guard assessment.requiredComponents.contains(.staticLinuxSDK)
                else { throw EnvironmentPreparationError.unauthorizedMutationRequired }

                await report(
                    .staticLinuxSDK,
                    "Installing the matching checksummed Static Linux SDK.",
                    to: onEvent
                )

                let installSDKCommand = swiftly.command(
                    tool: "swift",
                    toolchain: toolchain,
                    arguments: [
                        "sdk", "install", sdkMetadata.downloadURL.absoluteString,
                        "--checksum", sdkMetadata.checksum
                    ],
                    workingDirectory: temporaryDirectory
                )

                let removalPlan: EnvironmentRemovalPlan
                if installedToolchain {
                    removalPlan = try .environment(
                        toolchain: toolchain,
                        staticLinuxSDKIdentifier: sdk.identifier
                    )
                } else {
                    removalPlan = try .staticLinuxSDK(identifier: sdk.identifier)
                }
                try await record(removalPlan, using: recordRemovalPlan)
                try await checkedRun(installSDKCommand, onEvent: onEvent)
                state = try await inspect(swiftly, toolchain)
            }

            return InstalledComponents(swiftly: swiftly, inventory: state)
        } catch let error as EnvironmentPlanRecordingError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapError(error)
        }
    }

}

extension EnvironmentPreparer {

    private func bootstrapSwiftly(onEvent: SwiftlyKitEvent.Handler?) async throws {

        let stagingDirectory = temporaryDirectory.appending(
            path: "SwiftlyKit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

        do { try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false) }
        catch { throw EnvironmentPreparationError.downloadFailed }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let packageURL = stagingDirectory.appending(path: "swiftly.pkg")

        await report(.swiftly, "Downloading the official Swiftly installer from Swift.org.", to: onEvent)

        do {
            try await downloadPackage(Self.officialPackageURL, packageURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EnvironmentPreparationError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentPreparationError.downloadFailed
        }

        await report(.swiftly, "Verifying the installer signature and Apple trust.", to: onEvent)

        let verifySignatureCommand = SubprocessCommand(
            executableURL: URL(filePath: "/usr/sbin/pkgutil"),
            arguments: ["--check-signature", packageURL.path(percentEncoded: false)],
            workingDirectory: stagingDirectory
        )
        
        let signature = try await execute(verifySignatureCommand, onEvent: onEvent)

        let output = signature.combinedOutput
        let officialSigner = output.localizedCaseInsensitiveContains("Developer ID Installer: Swift Open Source")
        let appleTrust = output.localizedCaseInsensitiveContains("trusted by the Apple notary service")
            || output.localizedCaseInsensitiveContains("trusted by macOS")
        
        guard signature.succeeded, officialSigner, appleTrust
        else { throw EnvironmentPreparationError.packageSignatureRejected }

        await report(.swiftly, "Installing Swiftly for the current user.", to: onEvent)

        let installPackageCommand = SubprocessCommand(
            executableURL: URL(filePath: "/usr/sbin/installer"),
            arguments: ["-pkg", packageURL.path(percentEncoded: false), "-target", "CurrentUserHomeDirectory"],
            workingDirectory: stagingDirectory
        )
        try await checkedRun(installPackageCommand, onEvent: onEvent)

        await report(
            .swiftly,
            "Initializing Swiftly without modifying shell profiles or selecting a toolchain.",
            to: onEvent
        )

        let initializeSwiftlyCommand = SubprocessCommand(
            executableURL: homeDirectory.appending(path: ".swiftly/bin/swiftly"),
            arguments: [
                "init", "--no-modify-profile", "--skip-install",
                "--quiet-shell-followup", "--assume-yes"
            ],
            workingDirectory: stagingDirectory
        )
        try await checkedRun(initializeSwiftlyCommand, onEvent: onEvent)
    }

    private func checkedRun(_ command: SubprocessCommand, onEvent: SwiftlyKitEvent.Handler?) async throws {
        
        let result = try await execute(command, onEvent: onEvent)
        guard result.succeeded
        else { throw EnvironmentPreparationError.installationFailed(Self.bounded(result.combinedOutput)) }
    }

    private func execute(_ command: SubprocessCommand, onEvent: SwiftlyKitEvent.Handler?) async throws -> SubprocessResult {
        do {
            return try await runner.run(command, onOutput: CommandOutputChunk.handler(for: onEvent))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentPreparationError.commandCouldNotRun(command.executableURL)
        }
    }

    private func report(_ component: PreparationComponent, _ detail: String, to handler: SwiftlyKitEvent.Handler?) async {

        let progress = OperationProgress(
            operation: .preparingEnvironment,
            component: component,
            detail: detail
        )
        
        await handler?(.progress(progress))
    }

}

extension EnvironmentPreparer {

    private func record(_ plan: EnvironmentRemovalPlan, using recorder: EnvironmentRemovalPlan.Recorder?) async throws {

        guard let recorder else { return }

        do {
            try await recorder(plan)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentPlanRecordingError(underlying: error)
        }
    }

    private static func bounded(_ value: String) -> String {
        String(value.prefix(8 * 1024))
    }

    private static func mapError(_ error: any Error) -> SwiftlyKitError {
        switch error {
            case let error as SwiftlyKitError: return error
            case let error as EnvironmentPreparationError: return error.swiftlyKitError
            case let error as InstalledEnvironmentError: return error.swiftlyKitError
            default: return .swiftlyInstallationFailed("An unexpected environment error occurred.")
        }
    }

}

extension EnvironmentPreparer {

    private struct InstalledComponents {

        let swiftly: SwiftlyInstallation
        let inventory: InstalledEnvironmentInventory
    }

}

/// Preserves a removal-plan recorder error until the public facade returns it unchanged.
struct EnvironmentPlanRecordingError: Error {

    let underlying: any Error

}

extension EnvironmentPreparer {

    private static let officialPackageURL = URL(string: "https://download.swift.org/swiftly/darwin/swiftly.pkg")!

}
