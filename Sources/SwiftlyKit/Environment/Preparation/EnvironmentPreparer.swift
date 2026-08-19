import Foundation

/// Prepares exactly the environment authorized by an accepted assessment.
struct EnvironmentPreparer {

    private(set) var homeDirectory: URL
    private(set) var temporaryDirectory: URL
    private(set) var runner: any SubprocessRunning
    private(set) var assessHost: @Sendable () async throws -> HostReadiness
    private(set) var downloadPackage: @Sendable (URL, URL) async throws -> Void
    private(set) var detectSwiftlyInStorage: @Sendable (EnvironmentStorage) async throws -> SwiftlyInstallation?
    private(set) var inspect: @Sendable (SwiftlyInstallation, SwiftVersion) async throws -> InstalledEnvironmentInventory
    private(set) var locateSDK: @Sendable (String) -> URL?
    private(set) var revalidate: @Sendable (EnvironmentAssessment) async throws -> Void

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        runner: any SubprocessRunning = LiveSubprocessRunner(),
        assessHost: @escaping @Sendable () async throws -> HostReadiness = {
            try await HostPreflight().assess()
        },
        downloadPackage: @escaping @Sendable (URL, URL) async throws -> Void = {
            try await HTTPPackageDownloader().download(from: $0, to: $1)
        },
        detectSwiftly: (@Sendable () async throws -> SwiftlyInstallation?)? = nil,
        inspect: @escaping @Sendable (SwiftlyInstallation, SwiftVersion) async throws
            -> InstalledEnvironmentInventory = { swiftly, toolchain in
            try await InstalledEnvironmentInspector().inspect(
                swiftly: swiftly,
                selectedToolchain: toolchain
            )
        },
        locateSDK: @escaping @Sendable (String) -> URL? = {
            SDKBundleLocator.locate(identifier: $0)
        },
        revalidate: @escaping @Sendable (EnvironmentAssessment) async throws -> Void = {
            try $0.packageInputs.validateCurrent()
        }
    ) {
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.runner = runner
        self.assessHost = assessHost
        self.downloadPackage = downloadPackage
        let legacyDetector = detectSwiftly
        if let legacyDetector {
            self.detectSwiftlyInStorage = { _ in try await legacyDetector() }
        } else {
            self.detectSwiftlyInStorage = { storage in
                try await SwiftlyInstallation.detect(
                    storage: storage,
                    homeDirectory: homeDirectory
                )
            }
        }
        self.inspect = inspect
        self.locateSDK = locateSDK
        self.revalidate = revalidate
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

            guard let sdkBundleURL = locateSDK(
                assessment.staticLinuxSDK.identifier,
                in: assessment.environmentStorage
            ) else {
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
        recordRemovalPlan: EnvironmentRemovalPlan.Recorder?,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws -> InstalledComponents {

        do {
            var swiftly = try await detectSwiftlyInStorage(assessment.environmentStorage)
        
            if swiftly == nil {
                guard assessment.requiredComponents.contains(.swiftly)
                else { throw EnvironmentPreparationError.swiftlyUnavailableAfterInstallation }
            
                try await bootstrapSwiftly(storage: assessment.environmentStorage, onEvent: onEvent)
                swiftly = try await detectSwiftlyInStorage(assessment.environmentStorage)
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

    private func bootstrapSwiftly(storage: EnvironmentStorage, onEvent: SwiftlyKitEvent.Handler?) async throws {

        let stagingDirectory = temporaryDirectory.appending(
            path: "SwiftlyKit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

        do { try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false) }
        catch { throw EnvironmentPreparationError.downloadFailed }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let packageURL = stagingDirectory.appending(path: "swiftly.pkg")

        await report(
            .swiftly,
            step: .downloading,
            detail: "Downloading the official Swiftly installer from Swift.org.",
            to: onEvent
        )

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

        await report(
            .swiftly,
            step: .verifying,
            detail: "Verifying the installer signature and Apple trust.",
            to: onEvent
        )

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

        let location = try storage.resolved(homeDirectory: homeDirectory)

        if case .standard = storage {
            await report(
                .swiftly,
                step: .installing,
                detail: "Installing Swiftly for the current user.",
                to: onEvent
            )

            let installPackageCommand = SubprocessCommand(
                executableURL: URL(filePath: "/usr/sbin/installer"),
                arguments: ["-pkg", packageURL.path(percentEncoded: false), "-target", "CurrentUserHomeDirectory"],
                workingDirectory: stagingDirectory
            )
            try await checkedRun(installPackageCommand, onEvent: onEvent)
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

        let initializeSwiftlyCommand = SubprocessCommand(
            executableURL: location.binDirectory.appending(path: "swiftly"),
            arguments: [
                "init", "--no-modify-profile", "--skip-install",
                "--quiet-shell-followup", "--assume-yes"
            ],
            workingDirectory: stagingDirectory,
            environment: location.processEnvironment
        )
        try await checkedRun(initializeSwiftlyCommand, onEvent: onEvent)
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
        let expandCommand = SubprocessCommand(
            executableURL: URL(filePath: "/usr/sbin/pkgutil"),
            arguments: [
                "--expand-full",
                packageURL.path(percentEncoded: false),
                expandedDirectory.path(percentEncoded: false)
            ],
            workingDirectory: stagingDirectory
        )
        try await checkedRun(expandCommand, onEvent: onEvent)

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
                  FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)),
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
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let child = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let ancestor = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return child.starts(with: ancestor)
    }

    private func checkedRun(_ command: SubprocessCommand, onEvent: SwiftlyKitEvent.Handler?) async throws {
        
        let result = try await execute(command, onEvent: onEvent)
        guard result.succeeded
        else { throw EnvironmentPreparationError.installationFailed(Self.bounded(result.combinedOutput)) }
    }

    private func execute(_ command: SubprocessCommand, onEvent: SwiftlyKitEvent.Handler?) async throws -> SubprocessResult {
        do {
            return try await runner.run(command, onEvent: onEvent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentPreparationError.commandCouldNotRun(command.executableURL)
        }
    }

    private func report(
        _ component: PreparationComponent,
        step: OperationProgress.PreparationStep,
        detail: String,
        to handler: SwiftlyKitEvent.Handler?
    ) async {

        let progress = OperationProgress(
            operation: .preparingEnvironment(component: component, step: step),
            detail: detail
        )
        
        await handler?(.progress(progress))
    }

}

extension EnvironmentPreparer {

    private func locateSDK(_ identifier: String, in storage: EnvironmentStorage) -> URL? {

        switch storage {
            case .standard:
                return locateSDK(identifier)
            case .directory:
                return SDKBundleLocator.locate(identifier: identifier, in: storage)
        }
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
