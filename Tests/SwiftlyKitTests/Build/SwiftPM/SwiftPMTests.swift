import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftPM build system")
struct SwiftPMTests {

    @Test("Typed operations map to stable public errors")
    func typedErrorMapping() {

        let output = URL(filePath: "/tmp/output")
        let mappings: [(SwiftPMError, SwiftlyKitError)] = [
            (.malformedPackageDescription, .packageInspectionFailed("SwiftPM returned malformed package metadata.")),
            (.dependencyResolutionRequired, .dependencyResolutionRequired),
            (.executableNotFound("Tool"), .executableProductNotFound("Tool")),
            (.unsupportedProductResources("Tool"), .unsupportedProductResources("Tool")),
            (.invalidExecutable("invalid"), .executableVerificationFailed("invalid")),
            (.outputAlreadyExists(output), .outputAlreadyExists(output)),
            (.outputPublicationFailed(output), .outputPublicationFailed(output)),
            (.commandFailed(operation: .build, diagnostic: "build failed"), .buildFailed("build failed")),
            (.commandFailed(operation: .locatingBuildOutput, diagnostic: "missing output"), .buildFailed("missing output")),
            (.commandFailed(operation: .packageDescription, diagnostic: "invalid manifest"), .packageInspectionFailed("invalid manifest")),
            (.commandFailed(operation: .dependencyResolution, diagnostic: "unresolved"), .dependencyResolutionFailed("unresolved")),
            (.commandFailed(operation: .stripping, diagnostic: "objcopy failed"), .stripFailed("objcopy failed"))
        ]

        for (internalError, publicError) in mappings {
            #expect(internalError.swiftlyKitError == publicError)
        }
    }

    @Test("Build uses exact toolchain, SDK, product, configuration, scratch, and disables resolution")
    func exactBuildCommand() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .init(succeeded: true, standardOutput: packageJSON, standardError: ""),
                .init(succeeded: true, standardOutput: "built", standardError: ""),
                .init(succeeded: true, standardOutput: directory.path + "\n", standardError: "")
            ])
            let environment = buildEnvironment(in: directory)
            let scratch = directory.appending(path: "scratch")
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                configuration: .release,
                scratchDirectory: scratch,
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
            let build = commands[1]
            #expect(build.arguments.prefix(3) == ["run", "swift", "build"])
            #expect(build.arguments.suffix(1) == ["+6.2.1"])
            #expect(build.arguments.contains("--disable-automatic-resolution"))
            #expect(build.arguments.contains("--swift-sdks-path"))
            #expect(build.arguments.contains("aarch64-swift-linux-musl"))
            #expect(build.arguments.contains("Tool"))
            #expect(build.arguments.contains("release"))
            #expect(build.arguments.contains(scratch.path))
            #expect(build.environment?["CUSTOM"] == "value")
            #expect(build.environment?["HOME"] == ProcessInfo.processInfo.environment["HOME"])
            #expect(build.environment?["SWIFTLY_HOME_DIR"] == ProcessInfo.processInfo.environment["SWIFTLY_HOME_DIR"])
            #expect(build.environment?["SWIFTLY_TOOLCHAINS_DIR"] == ProcessInfo.processInfo.environment["SWIFTLY_TOOLCHAINS_DIR"])
            #expect(build.environment?["SWIFTLY_BIN_DIR"] == "/")
            #expect(commands[2].arguments.contains("--show-bin-path"))
        }
    }

    @Test("Build maps disabled resolution diagnostics to the dedicated internal error")
    func resolutionRequired() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .init(succeeded: true, standardOutput: packageJSON, standardError: ""),
                .init(succeeded: false, standardOutput: "", standardError: "automatic resolution is disabled")
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
            let runner = RecordingSubprocessRunner(results: [
                .init(succeeded: true, standardOutput: packageJSON, standardError: ""),
                .init(succeeded: true, standardOutput: "built", standardError: ""),
                .init(succeeded: true, standardOutput: directory.path + "\n", standardError: "")
            ])
            let environment = buildEnvironment(in: directory)
            let request = BuildRequest(ExecutableProduct(name: "Tool"))
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            await #expect(throws: SwiftPMError.unsupportedProductResources("Tool")) {
                try await swiftPM.build(request, using: environment)
            }
        }
    }

    @Test("Dependency resolution uses the exact toolchain and forwards progress and command output")
    func dependencyResolutionCommandAndEvents() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let runner = RecordingSubprocessRunner(results: [
                .init(succeeded: true, standardOutput: "resolved", standardError: "warning")
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
                "run", "swift", "package", "--package-path", directory.path,
                "resolve", "+6.2.1"
            ])
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
                .init(succeeded: false, standardOutput: "context", standardError: "resolution failed")
            ])
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            await #expect(throws: SwiftPMError.commandFailed(
                operation: .dependencyResolution,
                diagnostic: "resolution failed\ncontext"
            )) {
                try await swiftPM.resolveDependencies(using: buildEnvironment(in: directory))
            }
        }
    }

    @Test("Explicit stripping is reverified and the result is published without replacement")
    func stripAndPublish() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            let output = directory.appending(path: "PublishedTool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .init(succeeded: true, standardOutput: packageJSON, standardError: ""),
                .init(succeeded: true, standardOutput: "built", standardError: ""),
                .init(succeeded: true, standardOutput: directory.path + "\n", standardError: ""),
                .init(succeeded: true, standardOutput: "stripped", standardError: "")
            ])
            let events = SwiftPMEventRecorder()
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                configuration: .release,
                output: output,
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
            #expect(commands[3].arguments == [
                "run", "llvm-objcopy", "--strip-all", executable.path, "+6.2.1"
            ])
            #expect(await events.operations == [.building, .stripping, .publishing])
            #expect(await events.outputs == [
                EventOutput(stream: .standardOutput, text: "built"),
                EventOutput(stream: .standardOutput, text: "stripped")
            ])
        }
    }

}

private func buildEnvironment(in directory: URL) -> LocalBuildEnvironment {

    LocalBuildEnvironment(
        swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
        staticLinuxSDK: StaticLinuxSDK(identifier: "sdk", version: "1.0.0"),
        packageRoot: directory,
        swiftlyExecutableURL: URL(filePath: "/swiftly"),
        sdkBundleURL: directory.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64)
    )
}

private struct EventOutput: Equatable, Sendable {

    let stream: CommandOutput.Stream
    let text: String

}

private actor SwiftPMEventRecorder {

    private(set) var operations: [OperationProgress.Operation] = []
    private(set) var outputs: [EventOutput] = []

    func record(_ event: SwiftlyKitEvent) {
        switch event {
            case .progress(let progress):
                operations.append(progress.operation)
            case .output(let output):
                outputs.append(EventOutput(stream: output.stream, text: output.text))
        }
    }

}
