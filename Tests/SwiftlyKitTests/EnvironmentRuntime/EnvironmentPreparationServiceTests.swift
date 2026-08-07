import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Environment preparation service")
struct EnvironmentPreparationServiceTests {

    private let version = SwiftVersion(major: 6, minor: 2, patch: 1)
    private let sdk = StaticLinuxSDKInstallation(
        identifier: "swift-6.2.1-RELEASE_static-linux-0.0.1",
        downloadURL: URL(string: "https://download.swift.org/swift-6.2.1/sdk.tar.gz")!,
        checksum: String(repeating: "a", count: 64)
    )

    @Test("A ready environment performs no download or mutation command")
    func readyIsNoOp() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"), version: "1.0.0")
        let commands = CommandRecorder(results: [])
        let validations = Counter()
        let service = EnvironmentPreparationService(
            run: { try await commands.run($0) },
            downloadPackage: { _, _ in Issue.record("download must not run"); return 200 },
            detectSwiftly: { swiftly },
            inspect: { _, _ in
                InstalledEnvironmentState(toolchainVersions: [version], sdkIdentifiers: [sdk.identifier])
            },
            revalidate: { _ in await validations.increment() }
        )

        let result = try await service.prepare(
            EnvironmentPreparationPlan(toolchain: version, sdk: sdk, requiresSwiftly: false)
        )

        #expect(result == swiftly)
        #expect(await validations.value == 1)
        #expect(await commands.commands.isEmpty)

    }

    @Test("Installs exact toolchain without use then checksummed SDK through it")
    func installsMissingComponents() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"), version: "1.0.0")
        let commands = CommandRecorder(results: [
            EnvironmentCommandResult(succeeded: true, standardOutput: "", standardError: ""),
            EnvironmentCommandResult(succeeded: true, standardOutput: "", standardError: "")
        ])
        let inspections = StateSequence(states: [
            InstalledEnvironmentState(toolchainVersions: [], sdkIdentifiers: []),
            InstalledEnvironmentState(toolchainVersions: [version], sdkIdentifiers: [])
        ])
        let service = EnvironmentPreparationService(
            run: { try await commands.run($0) },
            downloadPackage: { _, _ in 200 },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            revalidate: { _ in }
        )

        _ = try await service.prepare(
            EnvironmentPreparationPlan(toolchain: version, sdk: sdk, requiresSwiftly: false)
        )

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
                executableURL: temporaryDirectory.appending(path: "home/.swiftly/bin/swiftly"),
                version: "1.0.0"
            )
            let detection = DetectionSequence(values: [nil, installed])
            let commands = CommandRecorder(results: [
                EnvironmentCommandResult(
                    succeeded: true,
                    standardOutput: "Developer ID Installer: Swift Open Source; trusted by the Apple notary service",
                    standardError: ""
                ),
                EnvironmentCommandResult(succeeded: true, standardOutput: "", standardError: ""),
                EnvironmentCommandResult(succeeded: true, standardOutput: "", standardError: "")
            ])
            let service = EnvironmentPreparationService(
                homeDirectory: temporaryDirectory.appending(path: "home"),
                temporaryDirectory: temporaryDirectory,
                run: { try await commands.run($0) },
                downloadPackage: { source, destination in
                    #expect(source == EnvironmentPreparationService.officialPackageURL)
                    try Data("package".utf8).write(to: destination)
                    return 200
                },
                detectSwiftly: { try await detection.next() },
                inspect: { _, _ in
                    InstalledEnvironmentState(toolchainVersions: [version], sdkIdentifiers: [sdk.identifier])
                },
                revalidate: { _ in }
            )

            _ = try await service.prepare(
                EnvironmentPreparationPlan(toolchain: version, sdk: sdk, requiresSwiftly: true)
            )

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

}

private actor Counter {

    private(set) var value = 0

    func increment() { value += 1 }

}

private actor StateSequence {

    var states: [InstalledEnvironmentState]

    init(states: [InstalledEnvironmentState]) { self.states = states }

    func next() throws -> InstalledEnvironmentState {

        guard !states.isEmpty else { throw PreparationTestFailure.missingFixture }
        return states.removeFirst()

    }

}

private actor DetectionSequence {

    var values: [SwiftlyInstallation?]

    init(values: [SwiftlyInstallation?]) { self.values = values }

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
