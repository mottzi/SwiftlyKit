import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftlyKit fast track")
struct SwiftlyKitFastTrackTests {

    @Test("An unspecified product selects the sole executable")
    func soleProduct() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let executable = packageRoot.appending(path: "Tool")
            try writeELF(to: executable, architecture: .x86_64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: packageRoot.path + "\n")
            ])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner)

            let result = try await kit.build(
                packageRoot,
                product: nil,
                for: .linux(.x86_64),
                configuration: .release,
                onEvent: nil
            )

            #expect(result == executable)
            let commands = await runner.commands
            #expect(commands[2].arguments.contains("x86_64-swift-linux-musl"))
            #expect(commands[2].arguments.contains("Tool"))
            #expect(commands[2].arguments.contains("release"))
        }
    }

    @Test("An unspecified product rejects an ambiguous package")
    func ambiguousProduct() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let packageJSON = try packageDescriptionJSON(executableProducts: ["First", "Second"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON)
            ])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner)

            await #expect(throws: SwiftlyKitError.executableProductSelectionRequired(["First", "Second"])) {
                try await kit.build(
                    packageRoot,
                    product: nil,
                    for: .linux(.x86_64),
                    configuration: .release,
                    onEvent: nil
                )
            }
        }
    }

    @Test("A specified product selects that executable from an ambiguous package")
    func namedProduct() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let executable = packageRoot.appending(path: "Second")
            try writeELF(to: executable, architecture: .x86_64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["First", "Second"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: packageRoot.path + "\n")
            ])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner)

            let result = try await kit.build(
                packageRoot,
                product: "Second",
                for: .linux(.x86_64),
                configuration: .release,
                onEvent: nil
            )

            #expect(result == executable)
            #expect(await runner.commands[2].arguments.contains("Second"))
        }
    }

    @Test("The fast track resolves dependencies and retries the build")
    func dependencyResolution() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let executable = packageRoot.appending(path: "Tool")
            try writeELF(to: executable, architecture: .x86_64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: packageJSON),
                .failure(standardError: "automatic resolution is disabled"),
                .success(output: "resolved"),
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: packageRoot.path + "\n")
            ])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner)

            let result = try await kit.build(
                packageRoot,
                product: nil,
                for: .linux(.x86_64),
                configuration: .release,
                onEvent: nil
            )

            #expect(result == executable)
            let commands = await runner.commands
            #expect(commands[3].arguments.contains("resolve"))
            #expect(commands.count == 7)
        }
    }

}

private func fastTrackKit(packageRoot: URL, runner: RecordingSubprocessRunner) -> SwiftlyKit {

    let version = SwiftVersion(major: 6, minor: 2, patch: 1)
    let sdkIdentifier = "swift-6.2.1-RELEASE_static-linux-1.0.0"
    let swiftly = SwiftlyInstallation(executableURL: packageRoot.appending(path: "swiftly"))
    let inventory = InstalledEnvironmentInventory(
        toolchains: [version],
        sdks: [InstalledStaticLinuxSDK(
            toolchainVersion: version,
            identifier: sdkIdentifier
        )]
    )
    let release = OfficialStableRelease(
        version: version,
        staticLinuxSDK: StaticLinuxSDK(identifier: sdkIdentifier, version: "1.0.0"),
        staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
            downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
            checksum: String(repeating: "a", count: 64),
            supportedArchitectures: [.x86_64]
        )!
    )

    return SwiftlyKit(
        assessor: EnvironmentAssessor(
            checkHost: {},
            detectSwiftly: { swiftly },
            loadReleases: { [release] },
            inspectInventory: { _ in inventory },
            locateSDK: { _ in packageRoot.appending(path: "sdk.artifactbundle") }
        ),
        preparer: EnvironmentPreparer(
            runner: runner,
            checkHost: {},
            downloadPackage: { _, _ in Issue.record("download must not run"); return 200 },
            detectSwiftly: { swiftly },
            inspect: { _, _ in inventory },
            locateSDK: { _ in packageRoot.appending(path: "sdk.artifactbundle") }
        ),
        swiftPM: SwiftPM(
            runner: runner,
            validateEnvironment: { _ in }
        )
    )
}

private func withFastTrackTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {

    try await withTemporaryDirectory(prefix: "SwiftlyKit-FastTrack") { directory in
        try Data("// swift-tools-version: 6.0\n".utf8).write(to: directory.appending(path: "Package.swift"))
        return try await body(directory)
    }
}
