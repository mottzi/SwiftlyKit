import Foundation
import Testing
@testable import Triple

@Suite("Package inspection")
struct PackageInspectionTests {

    @Test("Configuration returns root products without loading or resolving the dependency graph")
    func rootConfiguration() async throws {
        try await withTemporaryDirectory(prefix: "Triple-config-test") { directory in
            let sdk = try makeSDK(in: directory, version: "27.0")
            let runner = RecordingSubprocessRunner(results: [.success(output: Self.packageJSON)])
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in },
                sourceRoots: { _, _ in
                    Issue.record("Configuration must not load the dependency graph")
                    return []
                }
            )
            let kit = Triple(
                mutationGate: MutationGate(lockFile: directory.appending(path: "mutation.lock")),
                assessor: EnvironmentAssessor(),
                preparer: EnvironmentPreparer(),
                swiftPM: swiftPM,
                remover: EnvironmentRemover()
            )
            let environment = Self.environment(in: directory, sdk: sdk)
            let configuration = try await kit.configurePackage(using: environment)

            #expect(configuration.environment.swiftVersion == environment.swiftVersion)
            #expect(configuration.environment.hostSDK == sdk)
            #expect(configuration.products.map(\.name) == ["Tool"])
            let commands = await runner.commands
            #expect(commands.count == 1)
            let command = try #require(commands.first)
            #expect(command.arguments.contains("dump-package"))
            #expect(!command.arguments.contains("show-dependencies"))
            #expect(!command.arguments.contains("resolve"))
            let scratchIndex = try #require(command.arguments.firstIndex(of: "--scratch-path"))
            let scratch = URL(filePath: command.arguments[scratchIndex + 1])
            #expect(!fileURLsOverlap(scratch, directory))
            #expect(SwiftPMScratchStorage.configuration(for: directory) == .directory(scratch))
            // Preserve existing root manifests and the same path claims used by old clients.
            #expect(scratch.deletingLastPathComponent().lastPathComponent == "Configuration")
            #expect(scratch.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "SwiftlyKit")
        }
    }

    @Test("Configuration retains the SDK that recovered root evaluation without changing Swift")
    func rootConfigurationRecovery() async throws {
        try await withTemporaryDirectory(prefix: "Triple-config-test") { directory in
            let active = try makeSDK(in: directory, version: "27.0")
            let older = try makeSDK(in: directory, version: "26.5")
            let runner = RecordingSubprocessRunner(results: [
                .failure(standardError: "compile command failed due to signal 11"),
                .success(output: Self.packageJSON)
            ])
            let scratch = directory.appending(path: "configuration-scratch")
            let configuration = try await Self.swiftPM(runner: runner, alternatives: [older]).configurePackage(
                using: Self.environment(in: directory, sdk: active),
                scratchStorage: .directory(scratch)
            )

            #expect(configuration.environment.hostSDK == older)
            #expect(configuration.environment.swiftVersion == SwiftVersion(major: 6, minor: 3, patch: 3))
            let commands = await runner.commands
            #expect(commands.count == 2)
            #expect(commands.allSatisfy { $0.arguments.contains("dump-package") && $0.arguments.last == "+6.3.3" })
            #expect(commands.allSatisfy { $0.arguments.contains(scratch.path(percentEncoded: false)) })
        }
    }

    @Test("A build loads one successful graph before compilation and retains the recovering SDK")
    func buildUsesOneGraph() async throws {
        try await withTemporaryDirectory(prefix: "Triple-build-graph-test") { directory in
            let active = try makeSDK(in: directory, version: "27.0")
            let older = try makeSDK(in: directory, version: "26.5")
            try writeELF(to: directory.appending(path: "Tool"), architecture: .x86_64)
            let graph = try Self.graphJSON(root: directory)
            let runner = RecordingSubprocessRunner(results: [
                .success(output: Self.packageJSON),
                .failure(standardError: "compile command failed due to signal 11"),
                .success(output: Self.packageJSON),
                .success(output: graph),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false))
            ])
            let swiftPM = Self.swiftPM(runner: runner, alternatives: [older])
            let result = try await swiftPM.build(
                BuildRequest(ExecutableProduct(name: "Tool")),
                using: Self.environment(in: directory, sdk: active)
            )

            #expect(result.executable == directory.appending(path: "Tool"))
            let commands = await runner.commands
            #expect(commands.count == 6)
            #expect(commands[1].arguments.contains("show-dependencies"))
            #expect(commands[3].arguments.contains("show-dependencies"))
            #expect(commands[4].arguments.contains("build"))
            #expect(commands[5].arguments.contains("--show-bin-path"))
            #expect(commands.suffix(4).allSatisfy {
                $0.environment?["SDKROOT"] == older.directory.path(percentEncoded: false)
            })
            #expect(commands.allSatisfy { $0.arguments.last == "+6.3.3" })
        }
    }

    @Test("Graph errors stop compilation even when root products are available")
    func invalidGraphStopsBuild() async throws {
        try await withTemporaryDirectory(prefix: "Triple-build-graph-test") { directory in
            let sdk = try makeSDK(in: directory, version: "26.5")
            let runner = RecordingSubprocessRunner(results: [
                .success(output: Self.packageJSON),
                .failure(standardError: "Dependency/Package.swift: error: cannot find 'missingDeclaration' in scope")
            ])
            await #expect(throws: SwiftPMError.self) {
                try await Self.swiftPM(runner: runner, alternatives: []).build(
                    BuildRequest(ExecutableProduct(name: "Tool")),
                    using: Self.environment(in: directory, sdk: sdk)
                )
            }
            let commands = await runner.commands
            #expect(commands.count == 2)
            #expect(commands.allSatisfy { !$0.arguments.contains("build") })
        }
    }

    @Test("Build resolution is explicit and a successful graph is reused after resolution")
    func buildResolutionPolicy() async throws {
        try await withTemporaryDirectory(prefix: "Triple-build-graph-test") { directory in
            let sdk = try makeSDK(in: directory, version: "26.5")
            try writeELF(to: directory.appending(path: "Tool"), architecture: .x86_64)
            let results: [SubprocessResult] = [
                .success(output: Self.packageJSON),
                .failure(standardError: "automatic resolution is disabled"),
                .success(output: "resolved"),
                .success(output: try Self.graphJSON(root: directory)),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false))
            ]
            let strictRunner = RecordingSubprocessRunner(results: Array(results.prefix(2)))
            await #expect(throws: SwiftPMError.dependencyResolutionRequired) {
                try await Self.swiftPM(runner: strictRunner, alternatives: []).build(
                    BuildRequest(ExecutableProduct(name: "Tool")),
                    using: Self.environment(in: directory, sdk: sdk)
                )
            }
            #expect(await strictRunner.commands.count == 2)

            let runner = RecordingSubprocessRunner(results: results)
            _ = try await Self.swiftPM(runner: runner, alternatives: []).build(
                BuildRequest(ExecutableProduct(name: "Tool")),
                using: Self.environment(in: directory, sdk: sdk),
                dependencies: .resolveIfNeeded
            )
            let commands = await runner.commands
            #expect(commands.count == 6)
            #expect(commands[2].arguments.contains("resolve"))
            #expect(commands[3].arguments.contains("show-dependencies"))
            #expect(commands[4].arguments.contains("build"))
        }
    }

    @Test("Compiler crash diagnostics retain the leading error before a long backtrace")
    func leadingDiagnostic() {
        let result = SubprocessResult(
            succeeded: false,
            standardOutput: "",
            standardError: "error: unknown argument: '-target-arch-variant'\n"
                + String(repeating: "stack frame\n", count: 3_000)
        )
        #expect(SwiftPM.boundedDiagnostic(result).contains("unknown argument"))
        #expect(SwiftPM.boundedDiagnostic(result).count <= 16_384)
    }

    @Test("Root discovery cannot hide a dependency compiler crash; the successful SDK remains bound")
    func dependencyCrashRecovery() async throws {
        try await withTemporaryDirectory(prefix: "Triple-host-test") { directory in
            let active = try makeSDK(in: directory, version: "27.0")
            let older = try makeSDK(in: directory, version: "26.5")
            let runner = RecordingSubprocessRunner(results: [
                .success(output: Self.packageJSON),
                .failure(standardError: "compile command failed due to signal 11\nerror: unknown argument: '-target-arch-variant'"),
                .success(output: Self.packageJSON),
                .success(output: Self.graphJSON)
            ])
            let swiftPM = Self.swiftPM(runner: runner, alternatives: [older])
            let environment = Self.environment(in: directory, sdk: active)
            let inspection = try await swiftPM.inspectPackage(using: environment)

            #expect(inspection.environment.swiftVersion == environment.swiftVersion)
            #expect(inspection.environment.hostSDK == older)
            #expect(inspection.products.map(\.name) == ["Tool"])
            let commands = await runner.commands
            #expect(commands.count == 4)
            #expect(commands[0].environment?["SDKROOT"] == active.directory.path(percentEncoded: false))
            #expect(commands[1].arguments.contains("show-dependencies"))
            #expect(commands[2].environment?["SDKROOT"] == older.directory.path(percentEncoded: false))
            #expect(commands.allSatisfy { $0.arguments.last == "+6.3.3" })
            #expect(commands.allSatisfy { $0.arguments.contains("--manifest-cache") })
            #expect(commands.allSatisfy { $0.environment?["SWIFTPM_MODULECACHE_OVERRIDE"] == nil })
            #expect(commands.allSatisfy { $0.environment?["CLANG_MODULE_CACHE_PATH"] == nil })
            let build = SwiftPM.command(inspection.environment, swiftArguments: ["build"])
            #expect(build.environment?["SDKROOT"] == older.directory.path(percentEncoded: false))
            #expect(build.environment?["DEVELOPER_DIR"] == older.developerDirectory.path(percentEncoded: false))
            #expect(build.environment?["SWIFTPM_MODULECACHE_OVERRIDE"] == nil)
            try inspection.environment.hostSDK?.validate()
            try FileManager.default.removeItem(at: older.directory)
            #expect(throws: TripleError.self) { try inspection.environment.hostSDK?.validate() }
        }
    }

    @Test("Cold dependency compiler failures recover even when fetch logs hide the marker", arguments: [false, true])
    func longDependencyCompilerFailureRecovers(duringResolution: Bool) async throws {
        try await withTemporaryDirectory(prefix: "Triple-host-test") { directory in
            let active = try makeSDK(in: directory, version: "27.0")
            let older = try makeSDK(in: directory, version: "26.5")
            let failure = SubprocessResult.failure(standardError:
                String(repeating: "Fetching https://example.com/dependency.git\n", count: 400)
                + "error: 'dependency': Invalid manifest\nerror: compile command failed due to signal 11\n"
                + String(repeating: "compiler stack frame\n", count: 400)
            )
            #expect(!SwiftPM.boundedDiagnostic(failure).contains("compile command failed due to signal"))
            var results: [SubprocessResult] = [.success(output: Self.packageJSON)]
            if duringResolution { results.append(.failure(standardError: "automatic resolution is disabled")) }
            results += [failure, .success(output: Self.packageJSON), .success(output: Self.graphJSON)]
            let runner = RecordingSubprocessRunner(results: results)
            let environment = Self.environment(in: directory, sdk: active)
            let inspection = try await Self.swiftPM(runner: runner, alternatives: [older]).inspectPackage(
                using: environment,
                dependencies: .resolveIfNeeded
            )

            #expect(inspection.environment.swiftVersion == environment.swiftVersion)
            #expect(inspection.environment.hostSDK == older)
            #expect(inspection.products.map(\.name) == ["Tool"])
            let commands = await runner.commands
            #expect(commands.count == (duringResolution ? 5 : 4))
            #expect(commands[duringResolution ? 2 : 1].arguments.contains(duringResolution ? "resolve" : "show-dependencies"))
            #expect(commands.suffix(2).allSatisfy { $0.environment?["SDKROOT"] == older.directory.path(percentEncoded: false) })
            #expect(commands.allSatisfy { $0.arguments.last == "+6.3.3" })
        }
    }

    @Test("Long ordinary dependency failures retain bounded diagnostics without SDK retry", arguments: [false, true])
    func longOrdinaryDependencyFailure(duringResolution: Bool) async throws {
        try await withTemporaryDirectory(prefix: "Triple-host-test") { directory in
            let active = try makeSDK(in: directory, version: "27.0")
            let older = try makeSDK(in: directory, version: "26.5")
            let failure = SubprocessResult.failure(standardError:
                String(repeating: "Fetching https://example.com/dependency.git\n", count: 400)
                + "Dependency/Package.swift: error: cannot find 'missingDeclaration' in scope"
            )
            let diagnostic = SwiftPM.boundedDiagnostic(failure)
            #expect(diagnostic.count <= 16_384)
            #expect(diagnostic.contains("missingDeclaration"))
            var results: [SubprocessResult] = [.success(output: Self.packageJSON)]
            if duringResolution { results.append(.failure(standardError: "automatic resolution is disabled")) }
            results.append(failure)
            let runner = RecordingSubprocessRunner(results: results)
            let operation: SwiftPMError.Operation = duringResolution ? .resolvingDependencies : .inspectingPackage
            await #expect(throws: SwiftPMError.commandFailed(operation: operation, diagnostic: diagnostic)) {
                try await Self.swiftPM(runner: runner, alternatives: [older]).inspectPackage(
                    using: Self.environment(in: directory, sdk: active),
                    dependencies: .resolveIfNeeded
                )
            }
            #expect(await runner.commands.count == (duringResolution ? 3 : 2))
        }
    }

    @Test("Removed SDKs trigger real reinspection with a fresh installed context")
    func removedSDKReassesses() async throws {
        try await withTemporaryDirectory(prefix: "Triple-host-test") { directory in
            let removed = try makeSDK(in: directory, version: "26.5")
            let current = try makeSDK(in: directory, version: "27.0")
            let environment = Self.environment(in: directory, sdk: removed)
            try FileManager.default.removeItem(at: removed.directory)
            let runner = RecordingSubprocessRunner(results: [
                .success(output: Self.packageJSON),
                .success(output: Self.graphJSON)
            ])
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { try $0.hostSDK?.validate() },
                sourceRoots: { environment, scratch in
                    try await SwiftPM.packageGraphSourceRoots(
                        using: environment,
                        scratchDirectory: scratch,
                        runner: runner
                    )
                },
                hostSDKAlternatives: { _ in [] },
                activeHostSDK: { _ in current }
            )
            let inspection = try await swiftPM.inspectPackage(using: environment)
            #expect(inspection.environment.hostSDK == current)
            #expect(inspection.environment.swiftVersion == environment.swiftVersion)
            #expect(await runner.commands.count == 2)
        }
    }

    @Test("Invalid manifests and dependency resolution requirements do not trigger SDK retries")
    func ordinaryFailure() async throws {
        try await withTemporaryDirectory(prefix: "Triple-host-test") { directory in
            let active = try makeSDK(in: directory, version: "27.0")
            let runner = RecordingSubprocessRunner(results: [
                .failure(standardError: "Package.swift:4:1: error: cannot find 'typo' in scope")
            ])
            let swiftPM = Self.swiftPM(runner: runner, alternatives: [])
            await #expect(throws: SwiftPMError.self) {
                try await swiftPM.inspectPackage(using: Self.environment(in: directory, sdk: active))
            }
            #expect(await runner.commands.count == 1)
        }
    }

    @Test("Resolution remains opt-in and readiness follows successful graph inspection")
    func resolutionPolicy() async throws {
        try await withTemporaryDirectory(prefix: "Triple-host-test") { directory in
            let sdk = try makeSDK(in: directory, version: "26.5")
            let results: [SubprocessResult] = [
                .success(output: Self.packageJSON),
                .failure(standardError: "automatic resolution is disabled"),
                .success(),
                .success(output: Self.graphJSON)
            ]
            let runner = RecordingSubprocessRunner(results: results)
            let swiftPM = Self.swiftPM(runner: runner, alternatives: [])
            _ = try await swiftPM.inspectPackage(
                using: Self.environment(in: directory, sdk: sdk),
                dependencies: .resolveIfNeeded
            )
            #expect(await runner.commands.count == 4)
            #expect(await runner.commands[2].arguments.contains("resolve"))
            let strictRunner = RecordingSubprocessRunner(results: Array(results.prefix(2)))
            let strict = Self.swiftPM(runner: strictRunner, alternatives: [])
            await #expect(throws: SwiftPMError.dependencyResolutionRequired) {
                try await strict.inspectPackage(using: Self.environment(in: directory, sdk: sdk))
            }
            #expect(await strictRunner.commands.count == 2)
        }
    }

    @Test("SDK recovery exhaustion includes bounded compiler and SDK context and never yields readiness", arguments: [false, true])
    func exhaustedRecovery(withLongOutput: Bool) async throws {
        try await withTemporaryDirectory(prefix: "Triple-host-test") { directory in
            let sdk = try makeSDK(in: directory, version: "27.0")
            let output = "error: unknown argument: '-new-flag'\n"
                + (withLongOutput ? String(repeating: "Fetching dependency\n", count: 900) : "")
                + "compile command failed due to signal 11\n"
                + (withLongOutput ? String(repeating: "compiler stack frame\n", count: 400) : "")
            let runner = RecordingSubprocessRunner(results: [.failure(standardError: output)])
            do {
                _ = try await Self.swiftPM(runner: runner, alternatives: []).inspectPackage(
                    using: Self.environment(in: directory, sdk: sdk)
                )
                Issue.record("Inspection must fail when no host environment succeeds")
            } catch let error as TripleError {
                let diagnostic = error.localizedDescription
                #expect(diagnostic.contains("Swift 6.3.3"))
                #expect(diagnostic.contains(sdk.directory.path(percentEncoded: false)))
                #expect(diagnostic.contains("unknown argument"))
                #expect(diagnostic.contains("any installed macOS SDK"))
                #expect(diagnostic.count < 17_000)
                #expect(diagnostic.contains("diagnostic truncated") == withLongOutput)
            }
        }
    }

}

extension PackageInspectionTests {

    private static func graphJSON(root: URL) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "path": root.path(percentEncoded: false),
            "dependencies": []
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private static func swiftPM(runner: RecordingSubprocessRunner, alternatives: [HostSDK]) -> SwiftPM {
        SwiftPM(
            runner: runner,
            validateEnvironment: { _ in },
            sourceRoots: { environment, scratch in
                try await SwiftPM.packageGraphSourceRoots(
                    using: environment,
                    scratchDirectory: scratch,
                    runner: runner
                )
            },
            hostSDKAlternatives: { _ in alternatives }
        )
    }

    private static func environment(in directory: URL, sdk: HostSDK) -> LocalBuildEnvironment {
        LocalBuildEnvironment(
            swiftVersion: SwiftVersion(major: 6, minor: 3, patch: 3),
            staticLinuxSDK: StaticLinuxSDK(identifier: "test", version: "test"),
            packageRoot: directory,
            swiftly: SwiftlyInstallation(executableURL: URL(filePath: "/swiftly")),
            sdkBundleURL: directory.appending(path: "linux.artifactbundle"),
            target: .linux(.x86_64),
            swiftPMEnvironment: SwiftPMEnvironment.inherited.snapshot(inheriting: [:]),
            hostSDK: sdk
        )
    }

    private static let packageJSON = #"{"products":[{"name":"Tool","targets":["Tool"],"type":{"executable":null}}],"targets":[{"name":"Tool","type":"executable"}]}"#
    private static let graphJSON = #"{"path":"/package","dependencies":[]}"#

}

private func makeSDK(in directory: URL, version: String) throws -> HostSDK {
    let developer = directory.appending(path: "Developer-" + version)
    let sdk = developer.appending(path: "SDKs/MacOSX" + version + ".sdk")
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    try Data(("{\"Version\":\"" + version + "\"}").utf8).write(to: sdk.appending(path: "SDKSettings.json"))
    return try HostSDK(directory: sdk, developerDirectory: developer)
}
