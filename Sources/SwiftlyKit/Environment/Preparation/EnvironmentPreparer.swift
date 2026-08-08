import Foundation

/// Prepares exactly the environment authorized by an accepted assessment.
struct EnvironmentPreparer: Sendable {

    let homeDirectory: URL
    let temporaryDirectory: URL
    let runner: any SubprocessRunning
    let checkHost: @Sendable () async throws -> Void
    let downloadPackage: @Sendable (URL, URL) async throws -> Int
    let detectSwiftly: @Sendable () async throws -> SwiftlyInstallation?
    let inspect: @Sendable (SwiftlyInstallation, SwiftVersion) async throws -> InstalledEnvironmentInventory
    let locateSDK: @Sendable (String) -> URL?
    let revalidate: @Sendable (EnvironmentAssessment) async throws -> Void

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        runner: any SubprocessRunning = LiveSubprocessRunner(),
        checkHost: @escaping @Sendable () async throws -> Void = {
            _ = try await HostPreflight().check()
        },
        downloadPackage: @escaping @Sendable (URL, URL) async throws -> Int =
            EnvironmentPreparer.liveDownload,
        detectSwiftly: @escaping @Sendable () async throws -> SwiftlyInstallation? = {
            try await SwiftlyInstallation.detect()
        },
        inspect: @escaping @Sendable (SwiftlyInstallation, SwiftVersion) async throws -> InstalledEnvironmentInventory = { swiftly, toolchain in
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
        self.checkHost = checkHost
        self.downloadPackage = downloadPackage
        self.detectSwiftly = detectSwiftly
        self.inspect = inspect
        self.locateSDK = locateSDK
        self.revalidate = revalidate

    }

}

extension EnvironmentPreparer {

    /// Revalidates first, then performs only the mutations authorized by the assessment.
    func prepare(
        _ assessment: EnvironmentAssessment,
        onEvent: EventHandler? = nil
    ) async throws -> LocalBuildEnvironment {

        try await checkHost()
        try await revalidate(assessment)
        try Task.checkCancellation()
        let swiftly = try await installRequiredComponents(assessment, onEvent: onEvent)
        let inventory = try await inspect(swiftly, assessment.swiftVersion)
        guard inventory.contains(
            toolchain: assessment.swiftVersion,
            sdk: assessment.staticLinuxSDK.identifier
        ) else { throw EnvironmentPreparationError.unauthorizedMutationRequired }
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
            try await checkedRun(
                SubprocessCommand(
                    executableURL: swiftly.executableURL,
                    arguments: ["install", toolchain.description, "--verify", "--assume-yes"],
                    workingDirectory: temporaryDirectory
                ),
                onEvent: onEvent
            )
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
            guard sdk.downloadURL.scheme?.lowercased() == "https"
            else { throw EnvironmentPreparationError.invalidDownloadURL }
            guard sdk.checksum.count == 64 else { throw EnvironmentPreparationError.invalidDownloadURL }
            guard sdk.checksum.allSatisfy({ $0.isHexDigit }) else { throw EnvironmentPreparationError.invalidDownloadURL }
            await report(
                .staticLinuxSDK,
                "Installing the matching checksummed Static Linux SDK.",
                to: onEvent
            )
            try await checkedRun(InstalledEnvironmentInspector.swiftCommand(
                swiftly: swiftly.executableURL,
                toolchain: toolchain,
                arguments: [
                    "sdk", "install", sdk.downloadURL.absoluteString,
                    "--checksum", sdk.checksum
                ],
                workingDirectory: temporaryDirectory
            ), onEvent: onEvent)
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
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        } catch {
            throw EnvironmentPreparationError.downloadFailed
        }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let packageURL = stagingDirectory.appending(path: "swiftly.pkg")
        let statusCode: Int
        await report(.swiftly, "Downloading the official Swiftly installer from Swift.org.", to: onEvent)
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
        let signature = try await execute(SubprocessCommand(
            executableURL: URL(filePath: "/usr/sbin/pkgutil"),
            arguments: ["--check-signature", packageURL.path],
            workingDirectory: stagingDirectory
        ), onEvent: onEvent)
        let output = signature.combinedOutput
        let officialSigner = output.localizedCaseInsensitiveContains(
            "Developer ID Installer: Swift Open Source"
        )
        let appleTrust = output.localizedCaseInsensitiveContains("trusted by the Apple notary service")
            || output.localizedCaseInsensitiveContains("trusted by macOS")
        guard signature.succeeded else { throw EnvironmentPreparationError.packageSignatureRejected }
        guard officialSigner else { throw EnvironmentPreparationError.packageSignatureRejected }
        guard appleTrust else { throw EnvironmentPreparationError.packageSignatureRejected }

        await report(.swiftly, "Installing Swiftly for the current user.", to: onEvent)
        try await checkedRun(SubprocessCommand(
            executableURL: URL(filePath: "/usr/sbin/installer"),
            arguments: ["-pkg", packageURL.path, "-target", "CurrentUserHomeDirectory"],
            workingDirectory: stagingDirectory
        ), onEvent: onEvent)
        await report(
            .swiftly,
            "Initializing Swiftly without modifying shell profiles or selecting a toolchain.",
            to: onEvent
        )
        try await checkedRun(SubprocessCommand(
            executableURL: homeDirectory.appending(path: ".swiftly/bin/swiftly"),
            arguments: [
                "init", "--no-modify-profile", "--skip-install",
                "--quiet-shell-followup", "--assume-yes"
            ],
            workingDirectory: stagingDirectory
        ), onEvent: onEvent)

    }

    private func checkedRun(
        _ command: SubprocessCommand,
        onEvent: EventHandler?
    ) async throws {

        let result = try await execute(command, onEvent: onEvent)
        guard result.succeeded else {
            throw EnvironmentPreparationError.installationFailed(Self.bounded(result.combinedOutput))
        }

    }
    
    private func execute(
        _ command: SubprocessCommand,
        onEvent: EventHandler?
    ) async throws -> SubprocessResult {

        do {
            return try await runner.run(command, onOutput: CommandOutput.handler(for: onEvent))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentPreparationError.commandCouldNotRun(command.executableURL)
        }
    }
    
    private func report(
        _ component: PreparationComponent,
        _ detail: String,
        to handler: EventHandler?
    ) async {

        await handler?(.progress(OperationProgress(
            operation: .preparingEnvironment,
            component: component,
            detail: detail
        )))
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
