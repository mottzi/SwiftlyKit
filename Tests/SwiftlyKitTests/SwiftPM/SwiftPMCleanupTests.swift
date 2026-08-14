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

            try await swiftPM.cleanBuildArtifacts(
                in: .packageDefault,
                using: cleanupEnvironment(in: directory),
                onEvent: { await events.record($0) }
            )

            let commands = await runner.commands
            #expect(commands.count == 1)
            #expect(commands[0].arguments == [
                "run", "swift", "package", "clean", "--scratch-path",
                directory.appending(path: ".build").path(percentEncoded: false), "+6.2.1"
            ])
            #expect(commands[0].workingDirectory == directory)
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

            try await swiftPM.resetBuildStorage(
                in: .directory(scratch),
                using: cleanupEnvironment(in: directory),
                onEvent: { await events.record($0) }
            )

            let commands = await runner.commands
            #expect(commands.count == 1)
            #expect(commands[0].arguments == [
                "run", "swift", "package", "reset", "--scratch-path",
                scratch.path(percentEncoded: false), "+6.2.1"
            ])
            #expect(await events.operations == [.resettingBuildStorage])
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

    @Test("Build atomically copies before resetting explicit storage")
    func automaticReset() async throws {

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
                .success(output: "reset")
            ])
            let events = CleanupEventRecorder()
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                storage: .directory(scratch),
                output: .copy(to: output, cleanup: .reset)
            )

            let result = try await swiftPM.build(
                request,
                using: cleanupEnvironment(in: directory),
                onEvent: { await events.record($0) }
            )

            #expect(result == output)
            #expect(try Data(contentsOf: result) == Data(contentsOf: executable))
            let commands = await runner.commands
            #expect(commands.count == 4)
            #expect(commands[3].arguments.contains("reset"))
            let scratchOption = try #require(commands[3].arguments.firstIndex(of: "--scratch-path"))
            let scratchArgument = try #require(commands[3].arguments.dropFirst(scratchOption + 1).first)
            #expect(URL(filePath: scratchArgument).pathComponents == scratch.pathComponents)
            #expect(await events.operations == [.building, .copying, .resettingBuildStorage])
        }
    }

    @Test("A copied executable remains available when automatic cleanup fails")
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
                        storage: .directory(scratch),
                        output: .copy(to: output, cleanup: .reset)
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
                        storage: .directory(scratch),
                        output: .copy(to: output, cleanup: .clean)
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
                        storage: .directory(directory)
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

private func cleanupEnvironment(in directory: URL) -> LocalBuildEnvironment {

    LocalBuildEnvironment(
        swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
        staticLinuxSDK: StaticLinuxSDK(identifier: "sdk", version: "1.0.0"),
        packageRoot: directory,
        swiftly: SwiftlyInstallation(executableURL: URL(filePath: "/swiftly")),
        sdkBundleURL: directory.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64)
    )
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
