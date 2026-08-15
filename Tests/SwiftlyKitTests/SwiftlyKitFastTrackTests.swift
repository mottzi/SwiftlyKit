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
                .success(output: packageRoot.path(percentEncoded: false) + "\n")
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

    @Test("The fast track binds one SwiftPM environment snapshot to every phase")
    func swiftPMEnvironmentSnapshot() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let executable = packageRoot.appending(path: "Tool")
            try writeELF(to: executable, architecture: .x86_64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: packageRoot.path(percentEncoded: false) + "\n")
            ])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner)
            let values = try SwiftPMEnvironment([
                "BUILD_MODE": .plain("production"),
                "BUILD_TOKEN": .sensitive("private")
            ])

            _ = try await kit.build(
                packageRoot,
                product: nil,
                for: .linux(.x86_64),
                configuration: .release,
                swiftPMEnvironment: values,
                onEvent: nil
            )

            let commands = await runner.commands
            #expect(commands.count == 4)
            #expect(commands.allSatisfy { $0.environment?["BUILD_MODE"] == "production" })
            #expect(commands.allSatisfy { $0.environment?["BUILD_TOKEN"] == "private" })
            #expect(commands.allSatisfy { $0.sensitiveEnvironmentKeys == ["BUILD_TOKEN"] })
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
                .success(output: packageRoot.path(percentEncoded: false) + "\n")
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
                .success(output: packageRoot.path(percentEncoded: false) + "\n")
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

    @Test("The fast track forwards custom storage, copied output, and cleanup")
    func outputAndCleanup() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let executable = packageRoot.appending(path: "Tool")
            let scratch = packageRoot.appending(path: "scratch")
            let output = packageRoot.appending(path: "OutputTool")
            try writeELF(to: executable, architecture: .x86_64)
            try Data("previous output".utf8).write(to: output)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: packageRoot.path(percentEncoded: false) + "\n"),
                .success(output: "reset")
            ])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner)

            let result = try await kit.build(
                packageRoot,
                product: nil,
                for: .linux(.x86_64),
                configuration: .release,
                storage: .directory(scratch),
                output: .copy(to: output, replacingExisting: true, cleanup: .reset),
                onEvent: nil
            )

            #expect(result == output)
            let commands = await runner.commands
            #expect(commands.count == 5)
            let buildScratchOption = try #require(commands[2].arguments.firstIndex(of: "--scratch-path"))
            let buildScratchArgument = try #require(commands[2].arguments.dropFirst(buildScratchOption + 1).first)
            #expect(URL(filePath: buildScratchArgument).pathComponents == scratch.pathComponents)
            #expect(commands[4].arguments.contains("reset"))
            let resetScratchOption = try #require(commands[4].arguments.firstIndex(of: "--scratch-path"))
            let resetScratchArgument = try #require(commands[4].arguments.dropFirst(resetScratchOption + 1).first)
            #expect(URL(filePath: resetScratchArgument).pathComponents == scratch.pathComponents)
        }
    }

    @Test("The fast track selects an exact toolchain")
    func exactToolchain() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let selectedVersion = SwiftVersion(major: 6, minor: 2, patch: 1)
            let newerVersion = SwiftVersion(major: 6, minor: 3, patch: 0)
            let executable = packageRoot.appending(path: "Tool")
            try writeELF(to: executable, architecture: .x86_64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: packageRoot.path(percentEncoded: false) + "\n")
            ])
            let kit = fastTrackKit(
                packageRoot: packageRoot,
                runner: runner,
                versions: [selectedVersion, newerVersion]
            )

            _ = try await kit.build(
                packageRoot,
                product: nil,
                for: .linux(.x86_64),
                toolchain: .exact(selectedVersion),
                configuration: .release,
                onEvent: nil
            )

            let commands = await runner.commands
            #expect(commands[2].arguments.suffix(1) == ["+6.2.1"])
        }
    }

    @Test("The fast track forwards stripping without changing the SwiftPM executable")
    func strip() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let executable = packageRoot.appending(path: "Tool")
            let output = packageRoot.appending(path: "StrippedTool")
            try writeELF(to: executable, architecture: .x86_64)
            let originalBytes = try Data(contentsOf: executable)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: packageRoot.path(percentEncoded: false) + "\n"),
                .success(output: "stripped")
            ])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner)

            let result = try await kit.build(
                packageRoot,
                product: nil,
                for: .linux(.x86_64),
                configuration: .release,
                output: .copy(to: output),
                strip: true,
                onEvent: nil
            )

            #expect(result == output)
            #expect(try Data(contentsOf: executable) == originalBytes)
            let commands = await runner.commands
            #expect(commands.count == 5)
            #expect(commands[4].arguments.prefix(3) == ["run", "llvm-objcopy", "--strip-all"])
            #expect(commands[4].arguments[3] != executable.path(percentEncoded: false))
        }
    }

}

private func fastTrackKit(
    packageRoot: URL,
    runner: RecordingSubprocessRunner,
    versions: [SwiftVersion] = [SwiftVersion(major: 6, minor: 2, patch: 1)]
) -> SwiftlyKit {

    let swiftly = SwiftlyInstallation(executableURL: packageRoot.appending(path: "swiftly"))
    let inventory = InstalledEnvironmentInventory(
        toolchains: versions,
        sdks: versions.map { version in
            InstalledStaticLinuxSDK(
                toolchainVersion: version,
                identifier: sdkIdentifier(for: version)
            )
        }
    )
    let releases = versions.map { version in
        OfficialStableRelease(
            version: version,
            staticLinuxSDK: StaticLinuxSDK(identifier: sdkIdentifier(for: version), version: "1.0.0"),
            staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
                downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                checksum: String(repeating: "a", count: 64),
                supportedArchitectures: [.x86_64]
            )!
        )
    }

    return SwiftlyKit(
        assessor: EnvironmentAssessor(
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            loadReleases: { releases },
            inspectInventory: { _ in inventory },
            locateSDK: { _ in packageRoot.appending(path: "sdk.artifactbundle") }
        ),
        preparer: EnvironmentPreparer(
            runner: runner,
            assessHost: { .ready },
            downloadPackage: { _, _ in Issue.record("download must not run") },
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

private func sdkIdentifier(for version: SwiftVersion) -> String {
    "swift-\(version)-RELEASE_static-linux-1.0.0"
}

private func withFastTrackTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {

    try await withTemporaryDirectory(prefix: "SwiftlyKit-FastTrack") { directory in
        try Data("// swift-tools-version: 6.0\n".utf8).write(to: directory.appending(path: "Package.swift"))
        return try await body(directory)
    }
}
