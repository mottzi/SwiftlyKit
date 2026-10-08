import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Package inspection")
struct PackageInspectionTests {

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
        try await withTemporaryDirectory(prefix: "SwiftlyKit-host-test") { directory in
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
            #expect(throws: SwiftlyKitError.self) { try inspection.environment.hostSDK?.validate() }
        }
    }

    @Test("Removed SDKs trigger real reinspection with a fresh installed context")
    func removedSDKReassesses() async throws {
        try await withTemporaryDirectory(prefix: "SwiftlyKit-host-test") { directory in
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
        try await withTemporaryDirectory(prefix: "SwiftlyKit-host-test") { directory in
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
        try await withTemporaryDirectory(prefix: "SwiftlyKit-host-test") { directory in
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

    @Test("SDK recovery exhaustion includes compiler and SDK context and never yields readiness")
    func exhaustedRecovery() async throws {
        try await withTemporaryDirectory(prefix: "SwiftlyKit-host-test") { directory in
            let sdk = try makeSDK(in: directory, version: "27.0")
            let runner = RecordingSubprocessRunner(results: [
                .failure(standardError: "compile command failed due to signal 11\nerror: unknown argument: '-new-flag'")
            ])
            do {
                _ = try await Self.swiftPM(runner: runner, alternatives: []).inspectPackage(
                    using: Self.environment(in: directory, sdk: sdk)
                )
                Issue.record("Inspection must fail when no host environment succeeds")
            } catch let error as SwiftlyKitError {
                let diagnostic = error.localizedDescription
                #expect(diagnostic.contains("Swift 6.3.3"))
                #expect(diagnostic.contains(sdk.directory.path(percentEncoded: false)))
                #expect(diagnostic.contains("unknown argument"))
                #expect(diagnostic.contains("any installed macOS SDK"))
            }
        }
    }

}

extension PackageInspectionTests {

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
