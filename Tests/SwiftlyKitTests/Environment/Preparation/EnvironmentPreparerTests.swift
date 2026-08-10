import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Environment preparer")
struct EnvironmentPreparerTests {

    private let version = SwiftVersion(major: 6, minor: 2, patch: 1)
    private let sdk = StaticLinuxSDK(
        identifier: "swift-6.2.1-RELEASE_static-linux-0.0.1",
        version: "0.0.1"
    )
    private let sdkMetadata = StaticLinuxSDKMetadata(
        downloadURL: URL(string: "https://download.swift.org/swift-6.2.1/sdk.tar.gz")!,
        checksum: String(repeating: "a", count: 64),
        supportedArchitectures: [.arm64]
    )

    @Test("A ready environment inspects once and performs no download or mutation command")
    func readyIsNoOp() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [])
        let inspections = Counter()
        let validations = Counter()
        let preparer = EnvironmentPreparer(
            runner: commands,
            checkHost: {},
            downloadPackage: { _, _ in Issue.record("download must not run"); return 200 },
            detectSwiftly: { swiftly },
            inspect: { _, _ in
                await inspections.increment()
                return self.inventory(includesToolchain: true, includesSDK: true)
            },
            locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
            revalidate: { _ in await validations.increment() }
        )

        let result = try await preparer.prepare(try assessment(requires: []))

        #expect(result.swiftVersion == version)
        #expect(await inspections.value == 1)
        #expect(await validations.value == 1)
        #expect(await commands.commands.isEmpty)
    }

    @Test("Installs exact toolchain without use then checksummed SDK through it")
    func installsMissingComponents() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [
            SubprocessResult(succeeded: true, standardOutput: "", standardError: ""),
            SubprocessResult(succeeded: true, standardOutput: "", standardError: "")
        ])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: false, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: true)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            checkHost: {},
            downloadPackage: { _, _ in 200 },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
            revalidate: { _ in }
        )

        _ = try await preparer.prepare(try assessment(requires: [.toolchain, .staticLinuxSDK]))

        let recorded = await commands.commands
        #expect(await inspections.callCount == 3)
        #expect(recorded[0].arguments == ["install", "6.2.1", "--verify", "--assume-yes"])
        #expect(!recorded[0].arguments.contains("--use"))
        #expect(recorded[1].arguments == [
            "run", "swift", "sdk", "install", sdkMetadata.downloadURL.absoluteString,
            "--checksum", sdkMetadata.checksum, "+6.2.1"
        ])
    }

    @Test("Toolchain-only preparation reuses the post-install inventory")
    func toolchainOnlyReusesFinalInventory() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [
            SubprocessResult(succeeded: true, standardOutput: "", standardError: "")
        ])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: false, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: true)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            checkHost: {},
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
            revalidate: { _ in }
        )

        _ = try await preparer.prepare(try assessment(requires: [.toolchain]))

        #expect(await inspections.callCount == 2)
        #expect(await commands.commands.count == 1)
    }

    @Test("SDK installation refreshes inventory before validating preparation")
    func sdkInstallationRefreshesInventory() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [
            SubprocessResult(succeeded: true, standardOutput: "", standardError: "")
        ])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: true, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: false)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            checkHost: {},
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            revalidate: { _ in }
        )

        await #expect(throws: EnvironmentPreparationError.unauthorizedMutationRequired) {
            try await preparer.prepare(try assessment(requires: [.staticLinuxSDK]))
        }

        #expect(await inspections.callCount == 2)
        #expect(await commands.commands.count == 1)
    }

    @Test("Bootstrap validates trust and uses exact safe installer and init flags")
    func bootstrapCommands() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-EnvironmentPreparation") { temporaryDirectory in
            let installed = SwiftlyInstallation(
                executableURL: temporaryDirectory.appending(path: "home/.swiftly/bin/swiftly")
            )
            let detection = DetectionSequence(values: [nil, installed])
            let commands = RecordingSubprocessRunner(results: [
                SubprocessResult(
                    succeeded: true,
                    standardOutput: "Developer ID Installer: Swift Open Source; trusted by the Apple notary service",
                    standardError: ""
                ),
                SubprocessResult(succeeded: true, standardOutput: "", standardError: ""),
                SubprocessResult(succeeded: true, standardOutput: "", standardError: "")
            ])
            let preparer = EnvironmentPreparer(
                homeDirectory: temporaryDirectory.appending(path: "home"),
                temporaryDirectory: temporaryDirectory,
                runner: commands,
                checkHost: {},
                downloadPackage: { source, destination in
                    #expect(source == EnvironmentPreparer.officialPackageURL)
                    try Data("package".utf8).write(to: destination)
                    return 200
                },
                detectSwiftly: { try await detection.next() },
                inspect: { _, _ in self.inventory(includesToolchain: true, includesSDK: true) },
                locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
                revalidate: { _ in }
            )

            _ = try await preparer.prepare(try assessment(requires: [.swiftly]))

            let recorded = await commands.commands
            #expect(recorded[0].executableURL.path == "/usr/sbin/pkgutil")
            #expect(recorded[0].arguments.first == "--check-signature")
            #expect(recorded[1].arguments.suffix(2) == ["-target", "CurrentUserHomeDirectory"])
            #expect(recorded[2].arguments == [
                "init", "--no-modify-profile", "--skip-install",
                "--quiet-shell-followup", "--assume-yes"
            ])
        }
    }

    @Test("Bootstrap rejects unsuccessful downloads before running an installer command")
    func bootstrapRejectsHTTPFailure() async throws {

        let commands = RecordingSubprocessRunner(results: [])
        let preparer = EnvironmentPreparer(
            runner: commands,
            checkHost: {},
            downloadPackage: { _, _ in 503 },
            detectSwiftly: { nil },
            revalidate: { _ in }
        )

        await #expect(throws: EnvironmentPreparationError.invalidHTTPResponse(503)) {
            try await preparer.prepare(try assessment(requires: [.swiftly]))
        }
        #expect(await commands.commands.isEmpty)
    }

    @Test("Bootstrap rejects an untrusted package before installation")
    func bootstrapRejectsUntrustedPackage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-EnvironmentPreparation") { temporaryDirectory in
            let commands = RecordingSubprocessRunner(results: [
                SubprocessResult(
                    succeeded: true,
                    standardOutput: "Developer ID Installer: Unrelated Vendor; trusted by macOS",
                    standardError: ""
                )
            ])
            let preparer = EnvironmentPreparer(
                temporaryDirectory: temporaryDirectory,
                runner: commands,
                checkHost: {},
                downloadPackage: { _, destination in
                    try Data("package".utf8).write(to: destination)
                    return 200
                },
                detectSwiftly: { nil },
                revalidate: { _ in }
            )

            await #expect(throws: EnvironmentPreparationError.packageSignatureRejected) {
                try await preparer.prepare(try assessment(requires: [.swiftly]))
            }

            let recorded = await commands.commands
            #expect(recorded.count == 1)
            #expect(recorded[0].executableURL.path == "/usr/sbin/pkgutil")
        }
    }

    @Test("Preparation refuses mutations not authorized by the assessment")
    func unauthorizedMutationIsRejected() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [])
        let preparer = EnvironmentPreparer(
            runner: commands,
            checkHost: {},
            detectSwiftly: { swiftly },
            inspect: { _, _ in self.inventory(includesToolchain: false, includesSDK: false) },
            revalidate: { _ in }
        )

        await #expect(throws: EnvironmentPreparationError.unauthorizedMutationRequired) {
            try await preparer.prepare(try assessment(requires: []))
        }
        #expect(await commands.commands.isEmpty)
    }

    @Test("Download cancellation remains CancellationError")
    func downloadCancellationIsPreserved() async throws {

        let preparer = EnvironmentPreparer(
            checkHost: {},
            downloadPackage: { _, _ in throw CancellationError() },
            detectSwiftly: { nil },
            revalidate: { _ in }
        )

        await #expect(throws: CancellationError.self) {
            try await preparer.prepare(try assessment(requires: [.swiftly]))
        }
    }

    private func inventory(includesToolchain: Bool, includesSDK: Bool) -> InstalledEnvironmentInventory {

        InstalledEnvironmentInventory(
            toolchains: includesToolchain ? [version] : [],
            sdks: includesSDK ? [InstalledStaticLinuxSDK(
                toolchainVersion: version,
                identifier: sdk.identifier
            )] : []
        )
    }

    private func assessment(requires components: [PreparationComponent]) throws -> EnvironmentAssessment {

        try withTemporaryDirectory(prefix: "SwiftlyKit-EnvironmentAssessment") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8)
                .write(to: packageRoot.appending(path: "Package.swift"))

            return EnvironmentAssessment(
                packageInputs: try PackageInputSnapshot.capture(at: packageRoot),
                release: OfficialStableRelease(
                    version: version,
                    staticLinuxSDK: sdk,
                    staticLinuxSDKMetadata: sdkMetadata
                ),
                requiredComponents: components,
                target: .linux(.arm64)
            )
        }
    }

}

private actor Counter {

    private(set) var value = 0

    func increment() { value += 1 }

}

private actor InventorySequence {

    var inventories: [InstalledEnvironmentInventory]
    private(set) var callCount = 0

    init(inventories: [InstalledEnvironmentInventory]) {
        self.inventories = inventories
    }

    func next() throws -> InstalledEnvironmentInventory {
        callCount += 1
        guard !inventories.isEmpty else { throw PreparationTestFailure.missingFixture }
        return inventories.removeFirst()
    }

}

private actor DetectionSequence {

    var values: [SwiftlyInstallation?]

    init(values: [SwiftlyInstallation?]) {
        self.values = values
    }

    func next() throws -> SwiftlyInstallation? {
        guard !values.isEmpty else { throw PreparationTestFailure.missingFixture }
        return values.removeFirst()
    }

}

private enum PreparationTestFailure: Error {
    case missingFixture
}
