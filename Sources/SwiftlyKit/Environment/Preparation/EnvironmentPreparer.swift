import Foundation

/// Prepares exactly the environment authorized by an accepted assessment.
struct EnvironmentPreparer: Sendable {

    private let homeDirectory: URL
    private let temporaryDirectory: URL
    private let runner: any SubprocessRunning
    private let preparationState: any EnvironmentPreparationStateObserving
    private let packageDownloader: any PackageDownloading

    init() {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let runner = LiveSubprocessRunner()
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.runner = runner
        self.preparationState = LiveEnvironmentPreparationStateObserver(
            homeDirectory: homeDirectory,
            runner: runner
        )
        self.packageDownloader = HTTPPackageDownloader()
    }

    init(
        homeDirectory: URL,
        temporaryDirectory: URL,
        runner: any SubprocessRunning,
        preparationState: any EnvironmentPreparationStateObserving,
        packageDownloader: any PackageDownloading
    ) {
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.runner = runner
        self.preparationState = preparationState
        self.packageDownloader = packageDownloader
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

        try assessment.environmentStorage.validateNotOverlapping(assessment.packageRoot)
        let sharedStorage = try swiftPMSharedStorage.validated()
        if case .directory = assessment.environmentStorage,
           let location = try? assessment.environmentStorage.resolved(),
           [
               sharedStorage.cacheDirectory,
               sharedStorage.configurationDirectory,
               sharedStorage.securityDirectory
           ].compactMap({ $0 }).contains(where: {
               fileURLsOverlap(location.homeDirectory, $0)
           }) {
            throw SwiftlyKitError.unsafeEnvironmentStorage(location.homeDirectory)
        }

        do {
            var prepared = try await preparationState.preflight(assessment)
            try Task.checkCancellation()

            prepared = try await installRequiredComponents(
                assessment,
                initialState: prepared,
                recordRemovalPlan: recordRemovalPlan,
                onEvent: onEvent
            )

            guard prepared.inventory.contains(
                toolchain: assessment.swiftVersion,
                sdk: assessment.staticLinuxSDK.identifier
            ) else {
                throw SwiftlyKitError.staleAssessment
            }

            guard let swiftly = prepared.swiftly,
                  let sdkBundleURL = prepared.sdkBundleURL else {
                throw SwiftlyKitError.staleAssessment
            }

            return LocalBuildEnvironment(
                swiftVersion: assessment.swiftVersion,
                staticLinuxSDK: assessment.staticLinuxSDK,
                packageRoot: assessment.packageRoot,
                swiftly: swiftly,
                sdkBundleURL: sdkBundleURL,
                target: assessment.target,
                swiftPMEnvironment: swiftPMEnvironment,
                swiftPMTraits: swiftPMTraits,
                swiftPMSharedStorage: sharedStorage,
                environmentStorage: assessment.environmentStorage
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
        initialState: EnvironmentPreparationState,
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder?,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> EnvironmentPreparationState {

        do {
            var state = initialState
            if state.swiftly == nil {
                guard assessment.requiredComponents.contains(.swiftly)
                else { throw EnvironmentPreparationError.swiftlyUnavailableAfterInstallation }

                try await bootstrapSwiftly(
                    in: assessment.environmentStorage,
                    onEvent: onEvent
                )
                state = try await preparationState.refresh(assessment)
            }

            guard let swiftly = state.swiftly else {
                throw EnvironmentPreparationError.swiftlyUnavailableAfterInstallation
            }

            let toolchain = assessment.swiftVersion
            let sdk = assessment.release.staticLinuxSDK
            let sdkMetadata = assessment.release.staticLinuxSDKMetadata

            var installedToolchain = false

            if !state.inventory.contains(toolchain: toolchain) {
                guard assessment.requiredComponents.contains(.toolchain)
                else { throw EnvironmentPreparationError.unauthorizedMutationRequired }

                await report(
                    .toolchain,
                    step: .installing,
                    detail: "Installing Swift \(toolchain) without changing the selected default.",
                    to: onEvent
                )

                let installToolchainCommand = SubprocessCommand(
                    executableURL: swiftly.executableURL,
                    arguments: ["install", toolchain.description, "--verify", "--assume-yes"],
                    workingDirectory: temporaryDirectory,
                    environment: swiftly.processEnvironment
                )

                try await record(
                    .toolchain(toolchain, in: assessment.environmentStorage),
                    using: recordRemovalPlan
                )
                try await checkedRun(installToolchainCommand, onEvent: onEvent)
                installedToolchain = true

                state = try await preparationState.refresh(assessment)

                guard state.inventory.contains(toolchain: toolchain) else {
                    throw EnvironmentPreparationError.installationFailed(
                        "Swiftly did not report the selected toolchain after installation."
                    )
                }
            }

            if !state.inventory.contains(toolchain: toolchain, sdk: sdk.identifier) {
                guard assessment.requiredComponents.contains(.staticLinuxSDK)
                else { throw EnvironmentPreparationError.unauthorizedMutationRequired }

                await report(
                    .staticLinuxSDK,
                    step: .installing,
                    detail: "Installing the matching checksummed Static Linux SDK.",
                    to: onEvent
                )

                let installSDKCommand = swiftly.command(
                    tool: "swift",
                    toolchain: toolchain,
                    arguments: swiftly.sdkCommandArguments([
                        "sdk", "install", sdkMetadata.downloadURL.absoluteString,
                        "--checksum", sdkMetadata.checksum
                    ]),
                    workingDirectory: temporaryDirectory
                )

                let removalPlan: EnvironmentRemovalPlan
                if installedToolchain {
                    removalPlan = try .environment(
                        toolchain: toolchain,
                        staticLinuxSDKIdentifier: sdk.identifier,
                        in: assessment.environmentStorage
                    )
                } else {
                    removalPlan = try .staticLinuxSDK(
                        identifier: sdk.identifier,
                        in: assessment.environmentStorage
                    )
                }
                try await record(removalPlan, using: recordRemovalPlan)
                try await checkedRun(installSDKCommand, onEvent: onEvent)
                state = try await preparationState.refresh(assessment)
            }

            return state
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

    private func bootstrapSwiftly(
        in storage: EnvironmentStorage,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws {

        let stagingDirectory = temporaryDirectory.appending(
            path: "SwiftlyKit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw EnvironmentPreparationError.downloadFailed
        }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let packageURL = stagingDirectory.appending(path: "swiftly.pkg")
        await report(
            .swiftly,
            step: .downloading,
            detail: "Downloading the official Swiftly installer from Swift.org.",
            to: onEvent
        )

        do {
            try await packageDownloader.download(from: Self.officialPackageURL, to: packageURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EnvironmentPreparationError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentPreparationError.downloadFailed
        }

        await report(
            .swiftly,
            step: .verifying,
            detail: "Verifying the installer signature and Apple trust.",
            to: onEvent
        )
        let signature = try await execute(
            SubprocessCommand(
                executableURL: URL(filePath: "/usr/sbin/pkgutil"),
                arguments: ["--check-signature", packageURL.path(percentEncoded: false)],
                workingDirectory: stagingDirectory
            ),
            onEvent: onEvent
        )
        let output = signature.combinedOutput
        let officialSigner = output.localizedCaseInsensitiveContains(
            "Developer ID Installer: Swift Open Source"
        )
        let appleTrust = output.localizedCaseInsensitiveContains("trusted by the Apple notary service")
            || output.localizedCaseInsensitiveContains("trusted by macOS")
        guard signature.succeeded, officialSigner, appleTrust
        else { throw EnvironmentPreparationError.packageSignatureRejected }

        let location = try storage.resolved(homeDirectory: homeDirectory)
        if case .standard = storage {
            await report(
                .swiftly,
                step: .installing,
                detail: "Installing Swiftly for the current user.",
                to: onEvent
            )
            try await checkedRun(
                SubprocessCommand(
                    executableURL: URL(filePath: "/usr/sbin/installer"),
                    arguments: [
                        "-pkg", packageURL.path(percentEncoded: false),
                        "-target", "CurrentUserHomeDirectory"
                    ],
                    workingDirectory: stagingDirectory
                ),
                onEvent: onEvent
            )
        } else {
            await report(
                .swiftly,
                step: .installing,
                detail: "Installing Swiftly in the selected storage namespace.",
                to: onEvent
            )
            try await installCustomSwiftly(
                packageURL: packageURL,
                stagingDirectory: stagingDirectory,
                location: location,
                onEvent: onEvent
            )
        }

        await report(
            .swiftly,
            step: .initializing,
            detail: "Initializing Swiftly without modifying shell profiles or selecting a toolchain.",
            to: onEvent
        )
        try await checkedRun(
            SubprocessCommand(
                executableURL: location.binDirectory.appending(path: "swiftly"),
                arguments: [
                    "init", "--no-modify-profile", "--skip-install",
                    "--quiet-shell-followup", "--assume-yes"
                ],
                workingDirectory: stagingDirectory,
                environment: location.processEnvironment
            ),
            onEvent: onEvent
        )
    }

    private func installCustomSwiftly(
        packageURL: URL,
        stagingDirectory: URL,
        location: EnvironmentStorageLocation,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws {

        let expandedDirectory = stagingDirectory.appending(
            path: "expanded",
            directoryHint: .isDirectory
        )
        try await checkedRun(
            SubprocessCommand(
                executableURL: URL(filePath: "/usr/sbin/pkgutil"),
                arguments: [
                    "--expand-full",
                    packageURL.path(percentEncoded: false),
                    expandedDirectory.path(percentEncoded: false)
                ],
                workingDirectory: stagingDirectory
            ),
            onEvent: onEvent
        )

        let extractedSwiftly = try Self.locatePayloadExecutable(in: expandedDirectory)
        do {
            try FileManager.default.createDirectory(
                at: location.binDirectory,
                withIntermediateDirectories: true
            )
            let destination = location.binDirectory.appending(path: "swiftly")
            guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
                throw EnvironmentPreparationError.installationFailed(
                    "The selected Swiftly executable already exists."
                )
            }
            try FileManager.default.copyItem(at: extractedSwiftly, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: destination.path(percentEncoded: false)
            )
        } catch let error as EnvironmentPreparationError {
            throw error
        } catch {
            throw EnvironmentPreparationError.installationFailed(
                "The trusted Swiftly executable could not be installed."
            )
        }
    }

}

extension EnvironmentPreparer {

    private func report(
        _ component: PreparationComponent,
        step: OperationProgress.PreparationStep,
        detail: String,
        to handler: SwiftlyKitEvent.Handler?
    ) async {
        await handler?(.progress(OperationProgress(
            operation: .preparingEnvironment(component: component, step: step),
            detail: detail
        )))
    }

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

    private func checkedRun(_ command: SubprocessCommand, onEvent: SwiftlyKitEvent.Handler?) async throws {
        let result = try await execute(command, onEvent: onEvent)
        guard result.succeeded else {
            throw EnvironmentPreparationError.installationFailed(Self.bounded(result.combinedOutput))
        }
    }

    private func execute(
        _ command: SubprocessCommand,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> SubprocessResult {
        do {
            return try await runner.run(command, onEvent: onEvent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentPreparationError.commandCouldNotRun(command.executableURL)
        }
    }

}

extension EnvironmentPreparer {

    private static func mapError(_ error: any Error) -> SwiftlyKitError {
        switch error {
            case let error as SwiftlyKitError: return error
            case let error as EnvironmentPreparationError: return error.swiftlyKitError
            case let error as InstalledEnvironmentError: return error.swiftlyKitError
            default: return .swiftlyInstallationFailed("An unexpected environment error occurred.")
        }
    }

    private static func bounded(_ value: String) -> String {
        String(value.prefix(8 * 1024))
    }

}

extension EnvironmentPreparer {

    private static func locatePayloadExecutable(in expandedDirectory: URL) throws -> URL {

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: expandedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw EnvironmentPreparationError.installationFailed(
                "The expanded Swiftly package could not be inspected."
            )
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "Payload",
                  isDirectory(url),
                  !isSymbolicLink(url)
            else { continue }

            let executable = url.appending(path: "bin/swiftly")
            guard isRegularFile(executable),
                  fileManager.isExecutableFile(atPath: executable.path(percentEncoded: false)),
                  !isSymbolicLink(executable),
                  isDescendant(executable, of: expandedDirectory)
            else { continue }
            candidates.append(executable)
        }

        guard candidates.count == 1 else {
            throw EnvironmentPreparationError.installationFailed(
                "The Swiftly package did not contain exactly one safe Payload executable."
            )
        }
        return candidates[0]
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else { return false }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        return (attributes?[.type] as? FileAttributeType) == .typeRegular
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let child = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let ancestor = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return child.starts(with: ancestor)
    }

}

/// Preserves a removal-plan recorder error until the public facade returns it unchanged.
struct EnvironmentPlanRecordingError: Error {

    let underlying: any Error

}

extension EnvironmentPreparer {

    private static let officialPackageURL = URL(
        string: "https://download.swift.org/swiftly/darwin/swiftly.pkg"
    )!

}
