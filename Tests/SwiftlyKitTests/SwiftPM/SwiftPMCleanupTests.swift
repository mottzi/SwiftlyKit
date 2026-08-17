import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftPM build storage cleanup")
struct SwiftPMCleanupTests {

    @Test("Clean uses the selected toolchain and default package storage")
    func cleanDefaultStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Cleanup") { directory in
            let runner = RecordingSubprocessRunner(results: [
                .success(output: "cleaned", standardError: "warning")
            ])
            let events = CleanupEventRecorder()
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in
                Issue.record("cleanup must not require build environment validation")
            })
            let values = try SwiftPMEnvironment(["CLEAN_VALUE": .plain("enabled")])
            let environment = cleanupEnvironment(
                in: directory,
                swiftPMEnvironment: values.snapshot(inheriting: [:]),
                swiftPMTraits: try SwiftPMTraits(["CleanupFeature"], includingDefaults: false)
            )

            try await swiftPM.cleanBuildArtifacts(
                in: .packageDefault,
                using: environment,
                onEvent: { await events.record($0) }
            )

            let commands = await runner.commands
            #expect(commands.count == 1)
            #expect(commands[0].arguments == [
                "run", "swift", "package", "--traits", "CleanupFeature", "--scratch-path",
                directory.appending(path: ".build").path(percentEncoded: false), "clean", "+6.2.1"
            ])
            #expect(commands[0].workingDirectory == directory)
            #expect(commands[0].environment?["CLEAN_VALUE"] == "enabled")
            #expect(await events.operations == [.cleaningBuildArtifacts])
            #expect(await events.output == ["cleaned", "warning"])
        }
    }

    @Test("Reset uses an explicit scratch directory")
    func resetExplicitStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Cleanup") { directory in
            let scratch = directory.appending(path: "custom-scratch")
            let runner = RecordingSubprocessRunner(results: [.success()])
            let events = CleanupEventRecorder()
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })
            let values = try SwiftPMEnvironment(["RESET_VALUE": .plain("enabled")])
            let environment = cleanupEnvironment(
                in: directory,
                swiftPMEnvironment: values.snapshot(inheriting: [:]),
                swiftPMTraits: .none
            )

            try await swiftPM.resetBuildStorage(
                in: .directory(scratch),
                using: environment,
                onEvent: { await events.record($0) }
            )

            let commands = await runner.commands
            #expect(commands.count == 1)
            #expect(commands[0].arguments == [
                "run", "swift", "package", "--disable-default-traits", "--scratch-path",
                scratch.path(percentEncoded: false), "reset", "+6.2.1"
            ])
            #expect(commands[0].environment?["RESET_VALUE"] == "enabled")
            #expect(await events.operations == [.resettingBuildStorage])
        }
    }

    @Test("Cleanup configures shared SwiftPM locations without purging them")
    func cleanupKeepsSharedStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Cleanup") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let sharedRoot = directory.deletingLastPathComponent()
                .appending(path: "SwiftlyKit-cleanup-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
            let sharedStorage = SwiftPMSharedStorage(
                cacheDirectory: sharedRoot.appending(path: "cache", directoryHint: .isDirectory),
                configurationDirectory: sharedRoot.appending(path: "configuration", directoryHint: .isDirectory),
                securityDirectory: sharedRoot.appending(path: "security", directoryHint: .isDirectory)
            )
            defer { try? FileManager.default.removeItem(at: sharedRoot) }
            let runner = RecordingSubprocessRunner(results: [.success(), .success()])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })
            let environment = cleanupEnvironment(
                in: directory,
                swiftPMSharedStorage: sharedStorage
            )

            try await swiftPM.cleanBuildArtifacts(in: .directory(scratch), using: environment)
            try await swiftPM.resetBuildStorage(in: .directory(scratch), using: environment)

            let commands = await runner.commands
            #expect(commands.count == 2)
            for (command, subcommand) in zip(commands, ["clean", "reset"]) {
                let arguments = command.arguments
                let packageIndex = try #require(arguments.firstIndex(of: "package"))
                let subcommandIndex = try #require(arguments.firstIndex(of: subcommand))
                #expect(normalizedPath(try argument(after: "--scratch-path", in: arguments))
                    == normalizedPath(scratch.path(percentEncoded: false)))
                for (option, path) in [
                    ("--cache-path", sharedRoot.appending(path: "cache")),
                    ("--config-path", sharedRoot.appending(path: "configuration")),
                    ("--security-path", sharedRoot.appending(path: "security"))
                ] {
                    let optionIndex = try #require(arguments.firstIndex(of: option))
                    #expect(packageIndex < optionIndex)
                    #expect(optionIndex < subcommandIndex)
                    #expect(normalizedPath(try argument(after: option, in: arguments))
                        == normalizedPath(path.path(percentEncoded: false)))
                }
                #expect(!arguments.contains("purge-cache"))
            }
        }
    }

    @Test("Cleanup commands use the selected custom environment namespace")
    func cleanupUsesCustomEnvironmentStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Cleanup") { directory in
            let storageRoot = directory.deletingLastPathComponent().appending(path: "swiftly")
            let scratch = directory.deletingLastPathComponent().appending(path: "scratch")
            let runner = RecordingSubprocessRunner(results: [.success(), .success()])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })
            let environment = cleanupEnvironment(
                in: directory,
                environmentStorage: .directory(storageRoot)
            )

            try await swiftPM.cleanBuildArtifacts(in: .directory(scratch), using: environment)
            try await swiftPM.resetBuildStorage(in: .directory(scratch), using: environment)

            let commands = await runner.commands
            #expect(commands.count == 2)
            for command in commands {
                #expect(normalizedPath(command.environment?["SWIFTLY_HOME_DIR"] ?? "")
                    == normalizedPath(storageRoot.path(percentEncoded: false)))
                #expect(normalizedPath(command.environment?["SWIFTLY_BIN_DIR"] ?? "")
                    == normalizedPath(storageRoot.appending(path: "bin").path(percentEncoded: false)))
                #expect(normalizedPath(command.environment?["SWIFTLY_TOOLCHAINS_DIR"] ?? "")
                    == normalizedPath(storageRoot.appending(path: "toolchains").path(percentEncoded: false)))
            }
            #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        }
    }

    @Test("Cleanup failures retain their operation and bounded diagnostic")
    func cleanupFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Cleanup") { directory in
            let runner = RecordingSubprocessRunner(results: [
                .failure(output: "context", standardError: "reset failed")
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            await #expect(throws: SwiftPMError.commandFailed(
                operation: .resettingBuildStorage,
                diagnostic: "reset failed\ncontext"
            )) {
                try await swiftPM.resetBuildStorage(
                    in: .packageDefault,
                    using: cleanupEnvironment(in: directory)
                )
            }
        }
    }

    @Test("Build atomically publishes before resetting explicit storage")
    func automaticReset() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Cleanup") { directory in
            let scratch = directory.appending(path: "scratch")
            let binaryDirectory = scratch.appending(path: "bin")
            try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
            let executable = binaryDirectory.appending(path: "Tool")
            let output = directory.appending(path: "OutputTool")
            try writeELF(to: executable, architecture: .arm64)
            try Data("previous output".utf8).write(to: output)

            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                .success(output: "built"),
                .success(output: binaryDirectory.path(percentEncoded: false) + "\n"),
                .success(output: "reset")
            ])
            let events = CleanupEventRecorder()
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                scratchStorage: .directory(scratch),
                output: .publish(to: output, replacingExisting: true, cleanup: .reset)
            )

            let result = try await swiftPM.build(
                request,
                using: cleanupEnvironment(in: directory),
                onEvent: { await events.record($0) }
            )

            #expect(result.executable == output.appending(path: "Tool"))
            #expect(result.resourceBundles.isEmpty)
            #expect(try Data(contentsOf: result.executable) == Data(contentsOf: executable))
            let commands = await runner.commands
            #expect(commands.count == 4)
            #expect(commands[3].arguments.contains("reset"))
            let scratchOption = try #require(commands[3].arguments.firstIndex(of: "--scratch-path"))
            let scratchArgument = try #require(commands[3].arguments.dropFirst(scratchOption + 1).first)
            #expect(URL(filePath: scratchArgument).pathComponents == scratch.pathComponents)
            #expect(await events.operations == [.building, .publishing, .resettingBuildStorage])
        }
    }

    @Test("A published directory remains available when automatic cleanup fails")
    func automaticCleanupFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Cleanup") { directory in
            let scratch = directory.appending(path: "scratch")
            let binaryDirectory = scratch.appending(path: "bin")
            try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
            let executable = binaryDirectory.appending(path: "Tool")
            let output = directory.appending(path: "OutputTool")
            try writeELF(to: executable, architecture: .arm64)

            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                .success(output: "built"),
                .success(output: binaryDirectory.path(percentEncoded: false) + "\n"),
                .failure(standardError: "could not reset")
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            await #expect(throws: SwiftPMError.postBuildCleanupFailed(
                output: output,
                diagnostic: "could not reset"
            )) {
                try await swiftPM.build(
                    BuildRequest(
                        ExecutableProduct(name: "Tool"),
                        scratchStorage: .directory(scratch),
                        output: .publish(to: output, cleanup: .reset)
                    ),
                    using: cleanupEnvironment(in: directory)
                )
            }

            #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        }
    }

    @Test("Automatic cleanup rejects an output inside build storage before invoking SwiftPM")
    func rejectsInternalOutput() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Cleanup") { directory in
            let scratch = directory.appending(path: "scratch")
            let output = scratch.appending(path: "OutputTool")
            let runner = RecordingSubprocessRunner(results: [])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            await #expect(throws: SwiftPMError.outputInsideBuildStorage(output)) {
                try await swiftPM.build(
                    BuildRequest(
                        ExecutableProduct(name: "Tool"),
                        scratchStorage: .directory(scratch),
                        output: .publish(to: output, cleanup: .clean)
                    ),
                    using: cleanupEnvironment(in: directory)
                )
            }

            #expect(await runner.commands.isEmpty)
        }
    }

    @Test("Builds and cleanup reject storage containing the package root")
    func rejectsUnsafeStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Cleanup") { directory in
            let parent = directory.deletingLastPathComponent()
            let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
            let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
            let runner = RecordingSubprocessRunner(results: [])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            await #expect(throws: SwiftPMError.unsafeBuildStorage(resolvedDirectory)) {
                try await swiftPM.build(
                    BuildRequest(
                        ExecutableProduct(name: "Tool"),
                        scratchStorage: .directory(directory)
                    ),
                    using: cleanupEnvironment(in: directory)
                )
            }

            await #expect(throws: SwiftPMError.unsafeBuildStorage(resolvedParent)) {
                try await swiftPM.resetBuildStorage(
                    in: .directory(parent),
                    using: cleanupEnvironment(in: directory)
                )
            }

            await #expect(throws: SwiftPMError.unsafeBuildStorage(URL(filePath: "/"))) {
                try await swiftPM.cleanBuildArtifacts(
                    in: .directory(URL(filePath: "/")),
                    using: cleanupEnvironment(in: directory)
                )
            }

            #expect(await runner.commands.isEmpty)
        }
    }

}

private func cleanupEnvironment(
    in directory: URL,
    swiftPMEnvironment: SwiftPMEnvironment.Snapshot = SwiftPMEnvironment.inherited.snapshot(),
    swiftPMTraits: SwiftPMTraits = .packageDefaults,
    swiftPMSharedStorage: SwiftPMSharedStorage = .standard,
    environmentStorage: EnvironmentStorage = .standard
) -> LocalBuildEnvironment {

    let swiftlyURL: URL = switch environmentStorage {
        case .standard:
            URL(filePath: "/swiftly")
        case .directory(let root):
            root.appending(path: "bin/swiftly")
    }

    return LocalBuildEnvironment(
        swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
        staticLinuxSDK: StaticLinuxSDK(
            identifier: "sdk",
            version: "1.0.0"
        ),
        packageRoot: directory,
        swiftly: SwiftlyInstallation(executableURL: swiftlyURL),
        sdkBundleURL: directory.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64),
        swiftPMEnvironment: swiftPMEnvironment,
        swiftPMTraits: swiftPMTraits,
        swiftPMSharedStorage: swiftPMSharedStorage,
        environmentStorage: environmentStorage
    )
}

private func argument(after option: String, in arguments: [String]) throws -> String {
    let optionIndex = try #require(arguments.firstIndex(of: option))
    return try #require(arguments.dropFirst(optionIndex + 1).first)
}

private func normalizedPath(_ path: String) -> String {
    let normalized = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
    guard normalized != "/" else { return normalized }
    return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
}

private actor CleanupEventRecorder {

    private(set) var operations: [OperationProgress.Operation] = []
    private(set) var output: [String] = []

    func record(_ event: SwiftlyKitEvent) {
        switch event {
            case .progress(let progress): operations.append(progress.operation)
            case .output(let output): self.output.append(output.text)
        }
    }

}
