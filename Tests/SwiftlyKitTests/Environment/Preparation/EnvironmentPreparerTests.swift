import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Environment preparer")
struct EnvironmentPreparerTests {

    private let version = SwiftVersion(major: 6, minor: 2, patch: 1)
    private let sdk = OfficialStaticLinuxSDK(
        version: "0.0.1",
        identifier: "swift-6.2.1-RELEASE_static-linux-0.0.1",
        downloadURL: URL(string: "https://download.swift.org/swift-6.2.1/sdk.tar.gz")!,
        checksum: String(repeating: "a", count: 64),
        supportedArchitectures: [.arm64]
    )

    @Test("A ready environment performs no download or mutation command")
    func readyIsNoOp() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [])
        let validations = Counter()
        let preparer = EnvironmentPreparer(
            runner: commands,
            checkHost: {},
            downloadPackage: { _, _ in Issue.record("download must not run"); return 200 },
            detectSwiftly: { swiftly },
            inspect: { _, _ in self.inventory(includesToolchain: true, includesSDK: true) },
            locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
            revalidate: { _ in await validations.increment() }
        )

        let result = try await preparer.prepare(assessment(requires: []))

        #expect(result.swiftVersion == version)
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

        _ = try await preparer.prepare(assessment(requires: [.toolchain, .staticLinuxSDK]))

        let recorded = await commands.commands
        #expect(recorded[0].arguments == ["install", "6.2.1", "--verify", "--assume-yes"])
        #expect(!recorded[0].arguments.contains("--use"))
        #expect(recorded[1].arguments == [
            "run", "swift", "sdk", "install", sdk.downloadURL.absoluteString,
            "--checksum", sdk.checksum, "+6.2.1"
        ])
    }

    @Test("Bootstrap validates trust and uses exact safe installer and init flags")
    func bootstrapCommands() async throws {

        try await withTemporaryDirectory { temporaryDirectory in
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

            _ = try await preparer.prepare(assessment(requires: [.swiftly]))

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

    private func assessment(requires components: [PreparationComponent]) -> EnvironmentAssessment {

        let requirements = PackageRequirements(
            packageRoot: URL(filePath: "/tmp/package"),
            toolsVersion: SwiftVersion(major: 6, minor: 0, patch: 0),
            swiftVersion: nil,
            swiftVersionFileURL: nil
        )
        return EnvironmentAssessment(
            packageInputs: PackageInputSnapshot(
                requirements: requirements,
                manifest: Data(),
                swiftVersionFile: nil
            ),
            release: OfficialStableRelease(version: version, staticLinuxSDK: sdk),
            requiredComponents: components,
            target: .linux(.arm64)
        )
    }

    private func inventory(
        includesToolchain: Bool,
        includesSDK: Bool
    ) -> InstalledEnvironmentInventory {

        InstalledEnvironmentInventory(
            toolchains: includesToolchain ? [InstalledStableToolchain(version: version)] : [],
            sdks: includesSDK ? [InstalledStaticLinuxSDK(
                toolchainVersion: version,
                identifier: sdk.identifier
            )] : []
        )
    }

}

private actor Counter {

    private(set) var value = 0

    func increment() { value += 1 }

}

private actor InventorySequence {

    var inventories: [InstalledEnvironmentInventory]

    init(inventories: [InstalledEnvironmentInventory]) {
        self.inventories = inventories
    }

    func next() throws -> InstalledEnvironmentInventory {
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

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SwiftlyKit-EnvironmentPreparation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
