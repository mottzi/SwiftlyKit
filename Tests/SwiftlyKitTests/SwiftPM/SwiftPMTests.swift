import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftPM build system")
struct SwiftPMTests {

    @Test("Typed operations map to stable public errors")
    func typedErrorMapping() {

        let output = URL(filePath: "/tmp/output")
        let mappings: [(SwiftPMError, SwiftlyKitError)] = [
            (.sdkSearchPathPreparationFailed("unavailable"), .buildFailed("unavailable")),
            (.malformedPackageDescription, .packageInspectionFailed("SwiftPM returned malformed package metadata.")),
            (.dependencyResolutionRequired, .dependencyResolutionRequired),
            (.executableNotFound("Tool"), .executableProductNotFound("Tool")),
            (.unsupportedProductResources("Tool"), .unsupportedProductResources("Tool")),
            (.invalidExecutable("invalid"), .executableVerificationFailed("invalid")),
            (.unsafeBuildStorage(output), .unsafeBuildStorage(output)),
            (.outputInsideBuildStorage(output), .outputInsideBuildStorage(output)),
            (.outputAlreadyExists(output), .outputAlreadyExists(output)),
            (.outputCopyFailed(output), .outputCopyFailed(output)),
            (
                .postBuildCleanupFailed(output: output, diagnostic: "cleanup failed"),
                .postBuildCleanupFailed(output: output, detail: "cleanup failed")
            ),
            (.commandFailed(operation: .building, diagnostic: "build failed"), .buildFailed("build failed")),
            (.commandFailed(operation: .inspectingPackage, diagnostic: "invalid manifest"), .packageInspectionFailed("invalid manifest")),
            (.commandFailed(operation: .resolvingDependencies, diagnostic: "unresolved"), .dependencyResolutionFailed("unresolved")),
            (.commandFailed(operation: .stripping, diagnostic: "objcopy failed"), .stripFailed("objcopy failed")),
            (
                .commandFailed(operation: .cleaningBuildArtifacts, diagnostic: "clean failed"),
                .buildArtifactCleanupFailed("clean failed")
            ),
            (
                .commandFailed(operation: .resettingBuildStorage, diagnostic: "reset failed"),
                .buildStorageResetFailed("reset failed")
            )
        ]

        for (internalError, publicError) in mappings {
            #expect(internalError.swiftlyKitError == publicError)
        }
    }

    @Test(
        "Build uses exact toolchain, SDK, product, configuration, scratch, and disables resolution",
        arguments: [
            (configuration: BuildConfiguration.debug, argument: "debug"),
            (configuration: BuildConfiguration.release, argument: "release")
        ]
    )
    func exactBuildCommand(
        mapping: (configuration: BuildConfiguration, argument: String)
    ) async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path + "\n")
            ])
            let environment = buildEnvironment(in: directory)
            let scratch = directory.appending(path: "scratch")
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                configuration: mapping.configuration,
                storage: .directory(scratch),
                environment: [
                    "CUSTOM": "value",
                    "HOME": "/untrusted/home",
                    "SWIFTLY_BIN_DIR": "/untrusted/bin",
                    "SWIFTLY_HOME_DIR": "/untrusted/swiftly-home",
                    "SWIFTLY_TOOLCHAINS_DIR": "/untrusted/toolchains"
                ]
            )

            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            #expect(try await swiftPM.build(request, using: environment) == executable)
            let commands = await runner.commands
            #expect(commands.count == 3)
            #expect(commands.allSatisfy { $0.workingDirectory == directory })
            let build = commands[1]
            #expect(build.arguments.prefix(3) == ["run", "swift", "build"])
            #expect(build.arguments.suffix(1) == ["+6.2.1"])
            #expect(build.arguments.contains("--disable-automatic-resolution"))
            #expect(build.arguments.contains("--swift-sdks-path"))
            #expect(build.arguments.contains("aarch64-swift-linux-musl"))
            #expect(build.arguments.contains("Tool"))
            let configurationIndex = try #require(build.arguments.firstIndex(of: "--configuration"))
            #expect(build.arguments.dropFirst(configurationIndex + 1).first == mapping.argument)
            #expect(build.arguments.contains(scratch.path))
            #expect(build.environment?["CUSTOM"] == "value")
            #expect(build.environment?["HOME"] == ProcessInfo.processInfo.environment["HOME"])
            #expect(build.environment?["SWIFTLY_HOME_DIR"] == ProcessInfo.processInfo.environment["SWIFTLY_HOME_DIR"])
            #expect(build.environment?["SWIFTLY_TOOLCHAINS_DIR"] == ProcessInfo.processInfo.environment["SWIFTLY_TOOLCHAINS_DIR"])
            #expect(build.environment?["SWIFTLY_BIN_DIR"] == "/")
            #expect(commands[2].arguments.contains("--show-bin-path"))
        }
    }

    @Test("Consecutive builds reuse one scratch-scoped SDK search path")
    func consecutiveBuildSDKSearchPath() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(
                results: [
                    .success(output: packageJSON),
                    .success(output: "first build"),
                    .success(output: directory.path + "\n"),
                    .success(output: packageJSON),
                    .success(output: "second build"),
                    .success(output: directory.path + "\n")
                ]
            )
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                configuration: .release,
                storage: .directory(scratch)
            )
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )
            let environment = buildEnvironment(in: directory)

            _ = try await swiftPM.build(request, using: environment)
            _ = try await swiftPM.build(request, using: environment)

            let commands = await runner.commands
            #expect(commands.count == 6)
            let firstBuild = commands[1]
            let firstPath = try argument(after: "--swift-sdks-path", in: firstBuild.arguments)
            let secondBuild = commands[4]

            #expect(firstPath == (try argument(after: "--swift-sdks-path", in: commands[2].arguments)))
            #expect(firstPath == (try argument(after: "--swift-sdks-path", in: secondBuild.arguments)))
            #expect(firstPath == (try argument(after: "--swift-sdks-path", in: commands[5].arguments)))
            #expect(firstPath.hasPrefix(scratch.path + "/"))
        }
    }

    @Test("Default builds retain exact SDK selection in package scratch storage")
    func defaultSDKSearchPath() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let runner = RecordingSubprocessRunner(
                results: [
                    .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                    .success(output: "built"),
                    .success(output: directory.path + "\n")
                ]
            )
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            _ = try await swiftPM.build(
                BuildRequest(ExecutableProduct(name: "Tool")),
                using: buildEnvironment(in: directory)
            )

            let commands = await runner.commands
            #expect(
                try argument(after: "--swift-sdks-path", in: commands[1].arguments)
                    .hasPrefix(directory.appending(path: ".build").path + "/")
            )
        }
    }

    @Test("Build maps disabled resolution diagnostics to the dedicated internal error")
    func resolutionRequired() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .failure(standardError: "automatic resolution is disabled")
            ])
            let environment = buildEnvironment(in: directory)
            let request = BuildRequest(ExecutableProduct(name: "Tool"))
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            await #expect(throws: SwiftPMError.dependencyResolutionRequired) {
                try await swiftPM.build(request, using: environment)
            }
        }
    }

    @Test("Build rejects runtime resource bundles emitted by dependency products")
    func transitiveResources() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let resources = directory.appending(path: "Dependency_Assets.resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            try Data("asset".utf8).write(to: resources.appending(path: "asset.txt"))
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path + "\n")
            ])
            let events = SwiftPMEventRecorder()
            let environment = buildEnvironment(in: directory)
            let request = BuildRequest(ExecutableProduct(name: "Tool"))
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            await #expect(throws: SwiftPMError.unsupportedProductResources("Tool")) {
                try await swiftPM.build(
                    request,
                    using: environment,
                    onEvent: { await events.record($0) }
                )
            }
            #expect(await events.details.last == "Build produced unsupported runtime resource bundles: Dependency_Assets.resources.")
        }
    }

    @Test("Build ignores privacy-only resource bundles emitted by dependency products")
    func privacyMetadataResources() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let resources = directory.appending(path: "Dependency_Metadata.resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            try Data("privacy metadata".utf8).write(to: resources.appending(path: "PrivacyInfo.xcprivacy"))
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                .success(output: "built"),
                .success(output: directory.path + "\n")
            ])
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            #expect(
                try await swiftPM.build(
                    BuildRequest(ExecutableProduct(name: "Tool")),
                    using: buildEnvironment(in: directory)
                ) == executable
            )
        }
    }

    @Test("Dependency resolution uses the exact toolchain and forwards progress and command output")
    func dependencyResolutionCommandAndEvents() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let runner = RecordingSubprocessRunner(results: [
                .success(output: "resolved", standardError: "warning")
            ])
            let events = SwiftPMEventRecorder()
            let environment = buildEnvironment(in: directory)
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            try await swiftPM.resolveDependencies(
                using: environment,
                onEvent: { await events.record($0) }
            )

            let commands = await runner.commands
            #expect(commands.count == 1)
            #expect(commands[0].arguments == [
                "run", "swift", "package", "resolve", "+6.2.1"
            ])
            #expect(commands[0].workingDirectory == directory)
            #expect(await events.operations == [.resolvingDependencies])
            #expect(await events.outputs == [
                EventOutput(stream: .standardOutput, text: "resolved"),
                EventOutput(stream: .standardError, text: "warning")
            ])
        }
    }

    @Test("Dependency resolution failure retains a bounded diagnostic and operation")
    func dependencyResolutionFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let runner = RecordingSubprocessRunner(results: [
                .failure(output: "context", standardError: "resolution failed")
            ])
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            await #expect(throws: SwiftPMError.commandFailed(
                operation: .resolvingDependencies,
                diagnostic: "resolution failed\ncontext"
            )) {
                try await swiftPM.resolveDependencies(using: buildEnvironment(in: directory))
            }
        }
    }

    @Test("Explicit stripping prepares an atomic copy and preserves build storage")
    func stripAndCopy() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            let output = directory.appending(path: "PublishedTool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path + "\n"),
                .success(output: "stripped")
            ])
            let events = SwiftPMEventRecorder()
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                configuration: .release,
                output: .copy(to: output),
                strip: true
            )
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            let result = try await swiftPM.build(
                request,
                using: buildEnvironment(in: directory),
                onEvent: { await events.record($0) }
            )

            #expect(result == output)
            #expect(try Data(contentsOf: output) == Data(contentsOf: executable))
            let commands = await runner.commands
            #expect(commands.count == 4)
            let strippedExecutable = commands[3].arguments[3]
            #expect(commands[3].arguments.prefix(3) == ["run", "llvm-objcopy", "--strip-all"])
            #expect(commands[3].arguments.suffix(1) == ["+6.2.1"])
            #expect(strippedExecutable != executable.path)
            #expect(strippedExecutable != output.path)
            #expect(strippedExecutable.hasPrefix(directory.path + "/.PublishedTool.swiftlykit-"))
            #expect(!FileManager.default.fileExists(atPath: strippedExecutable))
            #expect(await events.operations == [.building, .stripping, .copying])
            #expect(await events.outputs == [
                EventOutput(stream: .standardOutput, text: "built"),
                EventOutput(stream: .standardOutput, text: "stripped")
            ])
        }
    }

    @Test("Stripped build-storage output leaves the SwiftPM executable unchanged")
    func stripInBuildStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            let strippedExecutable = directory.appending(path: ".Tool.swiftlykit-stripped")
            try writeELF(to: executable, architecture: .arm64)
            let originalBytes = try Data(contentsOf: executable)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path + "\n"),
                .success(output: "stripped")
            ])
            let events = SwiftPMEventRecorder()
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            let result = try await swiftPM.build(
                BuildRequest(ExecutableProduct(name: "Tool"), strip: true),
                using: buildEnvironment(in: directory),
                onEvent: { await events.record($0) }
            )

            #expect(result == strippedExecutable)
            #expect(try Data(contentsOf: executable) == originalBytes)
            #expect(try Data(contentsOf: strippedExecutable) == originalBytes)
            let commands = await runner.commands
            #expect(commands.count == 4)
            #expect(commands[3].arguments[3] != executable.path)
            #expect(commands[3].arguments[3] != strippedExecutable.path)
            #expect(await events.operations == [.building, .stripping])
        }
    }

    @Test("Strip failure preserves build storage and publishes no output")
    func stripFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            let output = directory.appending(path: "PublishedTool")
            try writeELF(to: executable, architecture: .arm64)
            let originalBytes = try Data(contentsOf: executable)
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                .success(output: "built"),
                .success(output: directory.path + "\n"),
                .failure(standardError: "strip failed")
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            await #expect(throws: SwiftPMError.commandFailed(
                operation: .stripping,
                diagnostic: "strip failed"
            )) {
                try await swiftPM.build(
                    BuildRequest(
                        ExecutableProduct(name: "Tool"),
                        output: .copy(to: output),
                        strip: true
                    ),
                    using: buildEnvironment(in: directory)
                )
            }

            #expect(try Data(contentsOf: executable) == originalBytes)
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
                !$0.hasPrefix(".PublishedTool.swiftlykit-")
            })
        }
    }

}

private func buildEnvironment(in directory: URL) -> LocalBuildEnvironment {

    LocalBuildEnvironment(
        swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
        staticLinuxSDK: StaticLinuxSDK(identifier: "sdk", version: "1.0.0"),
        packageRoot: directory,
        swiftly: SwiftlyInstallation(executableURL: URL(filePath: "/swiftly")),
        sdkBundleURL: directory.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64)
    )
}

private func argument(after option: String, in arguments: [String]) throws -> String {
    let optionIndex = try #require(arguments.firstIndex(of: option))
    return try #require(arguments.dropFirst(optionIndex + 1).first)
}

private struct EventOutput: Equatable {

    let stream: CommandOutputChunk.Stream
    let text: String

}

private actor SwiftPMEventRecorder {

    private(set) var operations: [OperationProgress.Operation] = []
    private(set) var details: [String] = []
    private(set) var outputs: [EventOutput] = []

    func record(_ event: SwiftlyKitEvent) {
        switch event {
            case .progress(let progress):
                operations.append(progress.operation)
                details.append(progress.detail)
            case .output(let output): outputs.append(EventOutput(stream: output.stream, text: output.text))
        }
    }

}
