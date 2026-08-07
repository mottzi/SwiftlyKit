import Foundation

/// Internal mutation boundary for preparing an exact Swiftly environment.
struct EnvironmentPreparationService: Sendable {

    static let officialPackageURL = URL(string: "https://download.swift.org/swiftly/darwin/swiftly.pkg")!

    let homeDirectory: URL
    let temporaryDirectory: URL
    let run: EnvironmentCommandRunner
    let downloadPackage: @Sendable (URL, URL) async throws -> Int
    let detectSwiftly: @Sendable () async throws -> SwiftlyInstallation?
    let inspect: @Sendable (SwiftlyInstallation, SwiftVersion) async throws -> InstalledEnvironmentState
    let revalidate: @Sendable (EnvironmentPreparationPlan) async throws -> Void

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        run: @escaping EnvironmentCommandRunner = EnvironmentProcess.run,
        downloadPackage: @escaping @Sendable (URL, URL) async throws -> Int =
            EnvironmentPreparationService.liveDownload,
        detectSwiftly: @escaping @Sendable () async throws -> SwiftlyInstallation? = {
            try await SwiftlyInstallation.detect()
        },
        inspect: @escaping @Sendable (SwiftlyInstallation, SwiftVersion) async throws -> InstalledEnvironmentState = { swiftly, toolchain in
            try await InstalledEnvironmentInspector().inspect(
                swiftly: swiftly,
                selectedToolchain: toolchain
            )
        },
        revalidate: @escaping @Sendable (EnvironmentPreparationPlan) async throws -> Void
    ) {

        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.run = run
        self.downloadPackage = downloadPackage
        self.detectSwiftly = detectSwiftly
        self.inspect = inspect
        self.revalidate = revalidate

    }

}

extension EnvironmentPreparationService {

    /// Revalidates first, then performs only mutations still required by live installed state.
    func prepare(
        _ plan: EnvironmentPreparationPlan,
        report: EnvironmentPreparationReporter? = nil
    ) async throws -> SwiftlyInstallation {

        try await revalidate(plan)
        try Task.checkCancellation()

        var swiftly = try await detectSwiftly()
        if swiftly == nil {
            guard plan.requiresSwiftly else { throw EnvironmentRuntimeError.swiftlyUnavailableAfterInstallation }
            try await bootstrapSwiftly(report: report)
            swiftly = try await detectSwiftly()
        }
        guard let swiftly else { throw EnvironmentRuntimeError.swiftlyUnavailableAfterInstallation }

        var state = try await inspect(swiftly, plan.toolchain)
        if !state.toolchainVersions.contains(plan.toolchain) {
            guard plan.requiresToolchain else { throw EnvironmentRuntimeError.unauthorizedMutationRequired }
            await report?(.toolchain, "Installing Swift \(plan.toolchain) without changing the selected default.")
            try await checkedRun(
                EnvironmentCommand(
                    executableURL: swiftly.executableURL,
                    arguments: ["install", plan.toolchain.description, "--verify", "--assume-yes"],
                    workingDirectory: temporaryDirectory
                )
            )
            state = try await inspect(swiftly, plan.toolchain)
            guard state.toolchainVersions.contains(plan.toolchain) else {
                throw EnvironmentRuntimeError.installationFailed(
                    "Swiftly did not report the selected toolchain after installation."
                )
            }
        }

        if !state.sdkIdentifiers.contains(plan.sdk.identifier) {
            guard plan.requiresSDK else { throw EnvironmentRuntimeError.unauthorizedMutationRequired }
            guard plan.sdk.downloadURL.scheme?.lowercased() == "https" else {
                throw EnvironmentRuntimeError.invalidDownloadURL
            }
            guard plan.sdk.checksum.count == 64,
                  plan.sdk.checksum.allSatisfy({ $0.isHexDigit })
            else { throw EnvironmentRuntimeError.invalidDownloadURL }
            await report?(.staticLinuxSDK, "Installing the matching checksummed Static Linux SDK.")
            try await checkedRun(InstalledEnvironmentInspector.swiftCommand(
                swiftly: swiftly.executableURL,
                toolchain: plan.toolchain,
                arguments: [
                    "sdk", "install", plan.sdk.downloadURL.absoluteString,
                    "--checksum", plan.sdk.checksum
                ],
                workingDirectory: temporaryDirectory
            ))
        }

        return swiftly

    }

}

extension EnvironmentPreparationService {

    private func bootstrapSwiftly(report: EnvironmentPreparationReporter?) async throws {

        guard Self.officialPackageURL.scheme == "https" else {
            throw EnvironmentRuntimeError.invalidDownloadURL
        }

        let stagingDirectory = temporaryDirectory.appending(
            path: "SwiftlyKit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        } catch {
            throw EnvironmentRuntimeError.downloadFailed
        }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let packageURL = stagingDirectory.appending(path: "swiftly.pkg")
        let statusCode: Int
        await report?(.swiftly, "Downloading the official Swiftly installer from Swift.org.")
        do {
            statusCode = try await downloadPackage(Self.officialPackageURL, packageURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentRuntimeError.downloadFailed
        }
        guard (200..<300).contains(statusCode) else {
            throw EnvironmentRuntimeError.invalidHTTPResponse(statusCode)
        }

        await report?(.swiftly, "Verifying the installer signature and Apple trust.")
        let signature = try await run(EnvironmentCommand(
            executableURL: URL(filePath: "/usr/sbin/pkgutil"),
            arguments: ["--check-signature", packageURL.path],
            workingDirectory: stagingDirectory
        ))
        let output = signature.combinedOutput
        let officialSigner = output.localizedCaseInsensitiveContains(
            "Developer ID Installer: Swift Open Source"
        )
        let appleTrust = output.localizedCaseInsensitiveContains("trusted by the Apple notary service")
            || output.localizedCaseInsensitiveContains("trusted by macOS")
        guard signature.succeeded, officialSigner, appleTrust else {
            throw EnvironmentRuntimeError.packageSignatureRejected
        }

        await report?(.swiftly, "Installing Swiftly for the current user.")
        try await checkedRun(EnvironmentCommand(
            executableURL: URL(filePath: "/usr/sbin/installer"),
            arguments: ["-pkg", packageURL.path, "-target", "CurrentUserHomeDirectory"],
            workingDirectory: stagingDirectory
        ))
        await report?(.swiftly, "Initializing Swiftly without modifying shell profiles or selecting a toolchain.")
        try await checkedRun(EnvironmentCommand(
            executableURL: homeDirectory.appending(path: ".swiftly/bin/swiftly"),
            arguments: [
                "init", "--no-modify-profile", "--skip-install",
                "--quiet-shell-followup", "--assume-yes"
            ],
            workingDirectory: stagingDirectory
        ))

    }

    private func checkedRun(_ command: EnvironmentCommand) async throws {

        let result = try await run(command)
        guard result.succeeded else {
            throw EnvironmentRuntimeError.installationFailed(Self.bounded(result.combinedOutput))
        }

    }

    private static func bounded(_ value: String) -> String {
        String(value.prefix(8 * 1024))
    }

    static func liveDownload(_ source: URL, _ destination: URL) async throws -> Int {

        guard source.scheme?.lowercased() == "https" else { throw EnvironmentRuntimeError.invalidDownloadURL }
        let (temporaryURL, response) = try await URLSession.shared.download(from: source)
        guard let response = response as? HTTPURLResponse else {
            throw EnvironmentRuntimeError.invalidHTTPResponse(0)
        }
        guard (200..<300).contains(response.statusCode) else { return response.statusCode }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return response.statusCode

    }

}
