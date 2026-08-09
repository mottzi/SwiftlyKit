import Foundation

/// Prepares exactly the environment authorized by an accepted assessment.
struct EnvironmentPreparer: Sendable {

    private(set) var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    private(set) var temporaryDirectory: URL = FileManager.default.temporaryDirectory
    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()

    private(set) var checkHost: @Sendable () async throws -> Void = {
        try await HostPreflight().check()
    }

    private(set) var downloadPackage: @Sendable (URL, URL) async throws -> Int = EnvironmentPreparer.liveDownload

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

}

extension EnvironmentPreparer {

    /// Revalidates first, then performs only the mutations authorized by the assessment.
    func prepare(_ assessment: EnvironmentAssessment, onEvent: EventHandler? = nil) async throws -> LocalBuildEnvironment {

        try await checkHost()
        try await revalidate(assessment)
        try Task.checkCancellation()

        let swiftly = try await installRequiredComponents(assessment, onEvent: onEvent)
        let inventory = try await inspect(swiftly, assessment.swiftVersion)

        guard inventory.contains(toolchain: assessment.swiftVersion, sdk: assessment.staticLinuxSDK.identifier)
        else { throw EnvironmentPreparationError.unauthorizedMutationRequired }

        let sdkBundleURL = locateSDK(assessment.staticLinuxSDK.identifier)
        guard let sdkBundleURL else { throw EnvironmentPreparationError.unauthorizedMutationRequired }

        return LocalBuildEnvironment(
            swiftVersion: assessment.swiftVersion,
            staticLinuxSDK: assessment.staticLinuxSDK,
            packageRoot: assessment.packageRoot,
            swiftlyExecutableURL: swiftly.executableURL,
            sdkBundleURL: sdkBundleURL,
            target: assessment.target
        )
    }

    private func installRequiredComponents(
        _ assessment: EnvironmentAssessment,
        onEvent: EventHandler?
    ) async throws -> SwiftlyInstallation {

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

        var state = try await inspect(swiftly, toolchain)

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

            try await checkedRun(installToolchainCommand, onEvent: onEvent)

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
            
            guard sdk.downloadURL.scheme?.lowercased() == "https",
                  sdk.checksum.count == 64,
                  sdk.checksum.allSatisfy(\.isHexDigit)
            else { throw EnvironmentPreparationError.invalidDownloadURL }
            
            await report(
                .staticLinuxSDK,
                "Installing the matching checksummed Static Linux SDK.",
                to: onEvent
            )

            let installSDKCommand = InstalledEnvironmentInspector.swiftCommand(
                swiftly: swiftly.executableURL,
                toolchain: toolchain,
                arguments: [
                    "sdk", "install", sdk.downloadURL.absoluteString,
                    "--checksum", sdk.checksum
                ],
                workingDirectory: temporaryDirectory
            )

            try await checkedRun(installSDKCommand, onEvent: onEvent)
        }

        return swiftly
    }

}

extension EnvironmentPreparer {

    private func bootstrapSwiftly(onEvent: EventHandler?) async throws {

        guard Self.officialPackageURL.scheme == "https" else { throw EnvironmentPreparationError.invalidDownloadURL }

        let stagingDirectory = temporaryDirectory.appending(
            path: "SwiftlyKit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

        do { try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false) }
        catch { throw EnvironmentPreparationError.downloadFailed }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let packageURL = stagingDirectory.appending(path: "swiftly.pkg")

        await report(.swiftly, "Downloading the official Swiftly installer from Swift.org.", to: onEvent)

        let statusCode: Int
        do {
            statusCode = try await downloadPackage(Self.officialPackageURL, packageURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentPreparationError.downloadFailed
        }

        guard (200..<300).contains(statusCode) else { throw EnvironmentPreparationError.invalidHTTPResponse(statusCode) }

        await report(.swiftly, "Verifying the installer signature and Apple trust.", to: onEvent)

        let verifySignatureCommand = SubprocessCommand(
            executableURL: URL(filePath: "/usr/sbin/pkgutil"),
            arguments: ["--check-signature", packageURL.path],
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
            arguments: ["-pkg", packageURL.path, "-target", "CurrentUserHomeDirectory"],
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

    private func checkedRun(_ command: SubprocessCommand, onEvent: EventHandler?) async throws {
        
        let result = try await execute(command, onEvent: onEvent)
        guard result.succeeded
        else { throw EnvironmentPreparationError.installationFailed(Self.bounded(result.combinedOutput)) }
    }

    private func execute(_ command: SubprocessCommand, onEvent: EventHandler?) async throws -> SubprocessResult {
        do {
            return try await runner.run(command, onOutput: CommandOutput.handler(for: onEvent))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentPreparationError.commandCouldNotRun(command.executableURL)
        }
    }

    private func report(_ component: PreparationComponent, _ detail: String, to handler: EventHandler?) async {

        let progress = OperationProgress(
            operation: .preparingEnvironment,
            component: component,
            detail: detail
        )
        
        await handler?(.progress(progress))
    }

    private static func bounded(_ value: String) -> String {
        String(value.prefix(8 * 1024))
    }

    static func liveDownload(_ source: URL, _ destination: URL) async throws -> Int {

        guard source.scheme?.lowercased() == "https" else { throw EnvironmentPreparationError.invalidDownloadURL }

        let (temporaryURL, response) = try await URLSession.shared.download(from: source)

        guard let response = response as? HTTPURLResponse else { throw EnvironmentPreparationError.invalidHTTPResponse(0) }
        guard (200..<300).contains(response.statusCode) else { return response.statusCode }

        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        
        return response.statusCode
    }

    static let officialPackageURL = URL(string: "https://download.swift.org/swiftly/darwin/swiftly.pkg")!

}
