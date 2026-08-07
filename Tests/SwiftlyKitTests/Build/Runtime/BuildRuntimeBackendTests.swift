import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Build runtime backend")
struct BuildRuntimeBackendTests {
    @Test("Build uses exact toolchain, SDK, product, configuration, scratch, and disables resolution")
    func exactBuildCommand() async throws {
        try await withBuildRuntimeTemporaryDirectory { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = """
                {"products":[{"name":"Tool","targets":["Tool"],"type":{"executable":null}}],
                 "targets":[{"name":"Tool","type":"executable","dependencies":[],"resources":[]}]}
                """
            let runner = RecordingBuildRuntimeRunner(results: [
                .init(succeeded: true, standardOutput: packageJSON, standardError: ""),
                .init(succeeded: true, standardOutput: "built", standardError: ""),
                .init(succeeded: true, standardOutput: directory.path + "\n", standardError: "")
            ])
            let environment = BuildRuntimeEnvironment(
                swiftlyExecutable: URL(filePath: "/swiftly"),
                toolchainSelector: "6.2.1",
                sdkID: "aarch64-swift-linux-musl",
                sdkArtifactBundle: directory.appending(path: "sdk.artifactbundle"),
                architecture: .arm64
            )
            let scratch = directory.appending(path: "scratch")
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                in: directory,
                for: .linux(.arm64),
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

            #expect(try await BuildRuntimeBackend(runner: runner).build(request, using: environment) == executable)
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
            #expect(build.environment["CUSTOM"] == "value")
            #expect(build.environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
            #expect(build.environment["SWIFTLY_HOME_DIR"] == ProcessInfo.processInfo.environment["SWIFTLY_HOME_DIR"])
            #expect(build.environment["SWIFTLY_TOOLCHAINS_DIR"] == ProcessInfo.processInfo.environment["SWIFTLY_TOOLCHAINS_DIR"])
            #expect(build.environment["SWIFTLY_BIN_DIR"] == "/")
            #expect(commands[2].arguments.contains("--show-bin-path"))
        }
    }

    @Test("Build maps disabled resolution diagnostics to the dedicated internal error")
    func resolutionRequired() async throws {
        try await withBuildRuntimeTemporaryDirectory { directory in
            let packageJSON = """
                {"products":[{"name":"Tool","targets":["Tool"],"type":{"executable":null}}],
                 "targets":[{"name":"Tool","type":"executable","dependencies":[],"resources":[]}]}
                """
            let runner = RecordingBuildRuntimeRunner(results: [
                .init(succeeded: true, standardOutput: packageJSON, standardError: ""),
                .init(succeeded: false, standardOutput: "", standardError: "automatic resolution is disabled")
            ])
            let environment = BuildRuntimeEnvironment(
                swiftlyExecutable: URL(filePath: "/swiftly"), toolchainSelector: "6.2.1",
                sdkID: "aarch64-swift-linux-musl", sdkArtifactBundle: directory.appending(path: "sdk.artifactbundle"),
                architecture: .arm64
            )
            let request = BuildRequest(ExecutableProduct(name: "Tool"), in: directory, for: .linux(.arm64))
            await #expect(throws: BuildRuntimeError.dependencyResolutionRequired) {
                try await BuildRuntimeBackend(runner: runner).build(request, using: environment)
            }
        }
    }
    
    @Test("Build rejects runtime resource bundles emitted by dependency products")
    func transitiveResources() async throws {
        
        try await withBuildRuntimeTemporaryDirectory { directory in
            let packageJSON = """
                {"products":[{"name":"Tool","targets":["Tool"],"type":{"executable":null}}],
                 "targets":[{"name":"Tool","type":"executable","dependencies":[],"resources":[]}]}
                """
            let resources = directory.appending(path: "Dependency_Assets.resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            let runner = RecordingBuildRuntimeRunner(results: [
                .init(succeeded: true, standardOutput: packageJSON, standardError: ""),
                .init(succeeded: true, standardOutput: "built", standardError: ""),
                .init(succeeded: true, standardOutput: directory.path + "\n", standardError: "")
            ])
            let environment = BuildRuntimeEnvironment(
                swiftlyExecutable: URL(filePath: "/swiftly"),
                toolchainSelector: "6.2.1",
                sdkID: "aarch64-swift-linux-musl",
                sdkArtifactBundle: directory.appending(path: "sdk.artifactbundle"),
                architecture: .arm64
            )
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                in: directory,
                for: .linux(.arm64)
            )
            await #expect(throws: BuildRuntimeError.unsupportedProductResources("Tool")) {
                try await BuildRuntimeBackend(runner: runner).build(request, using: environment)
            }
        }
    }
}

private actor RecordingBuildRuntimeRunner: BuildRuntimeProcessRunning {
    private var results: [BuildRuntimeProcessResult]
    private(set) var commands: [BuildRuntimeCommand] = []

    init(results: [BuildRuntimeProcessResult]) { self.results = results }

    func run(_ command: BuildRuntimeCommand, onOutput: BuildRuntimeOutputHandler?) async throws -> BuildRuntimeProcessResult {
        commands.append(command)
        return results.removeFirst()
    }
}
