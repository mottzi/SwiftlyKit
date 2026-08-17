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
                jobs: 2,
                onEvent: nil
            )

            #expect(result.executable == executable)
            #expect(result.resourceBundles.isEmpty)
            let commands = await runner.commands
            #expect(commands[2].arguments.contains("x86_64-swift-linux-musl"))
            #expect(commands[2].arguments.contains("Tool"))
            #expect(commands[2].arguments.contains("release"))
            #expect(try argument(after: "--jobs", in: commands[2].arguments) == "2")
            #expect(try argument(after: "--jobs", in: commands[3].arguments) == "2")
        }
    }

    @Test(
        "A nonpositive build job count fails before the fast track runs commands",
        arguments: [0, -1]
    )
    func invalidBuildJobs(jobs: Int) async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let runner = RecordingSubprocessRunner(results: [])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner)

            await #expect(throws: SwiftlyKitError.invalidBuildJobCount(jobs)) {
                try await kit.build(
                    packageRoot,
                    product: nil,
                    for: .linux(.x86_64),
                    configuration: .release,
                    jobs: jobs,
                    onEvent: nil
                )
            }

            #expect(await runner.commands.isEmpty)
        }
    }

    @Test("Invalid shared storage is rejected before staged or fast-track mutation")
    func invalidSharedStorage() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let runner = RecordingSubprocessRunner(results: [])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner, installed: false)
            let invalidDirectory = URL(string: "https://example.com/swiftpm-state")!
            let sharedStorage = SwiftPMSharedStorage(cacheDirectory: invalidDirectory)
            let assessment = try await kit.assess(packageRoot, for: .linux(.x86_64))

            await #expect(throws: SwiftlyKitError.unsafeSwiftPMSharedStorage(invalidDirectory)) {
                try await kit.prepare(
                    assessment,
                    swiftPMSharedStorage: sharedStorage
                )
            }
            await #expect(throws: SwiftlyKitError.unsafeSwiftPMSharedStorage(invalidDirectory)) {
                try await kit.build(
                    packageRoot,
                    product: nil,
                    for: .linux(.x86_64),
                    configuration: .release,
                    swiftPMSharedStorage: sharedStorage,
                    onEvent: nil
                )
            }

            #expect(await runner.commands.isEmpty)
        }
    }

    @Test("The fast track maps scratch and shared-storage overlap to the public error")
    func overlappingFastTrackStorage() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let runner = RecordingSubprocessRunner(results: [])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner)
            let scratch = packageRoot.appending(path: "scratch", directoryHint: .isDirectory)
            let sharedStorage = SwiftPMSharedStorage(cacheDirectory: scratch)
            let canonicalScratch = try CanonicalFileURL.resolve(scratch)

            await #expect(throws: SwiftlyKitError.unsafeSwiftPMSharedStorage(canonicalScratch)) {
                try await kit.build(
                    packageRoot,
                    product: nil,
                    for: .linux(.x86_64),
                    configuration: .release,
                    scratchStorage: .directory(scratch),
                    swiftPMSharedStorage: sharedStorage,
                    onEvent: nil
                )
            }

            #expect(await runner.commands.isEmpty)
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

    @Test("The fast track carries custom environment storage through every selected-tool command")
    func customEnvironmentStorageEnvironment() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let swiftlyRoot = packageRoot.deletingLastPathComponent().appending(path: "swiftly")
            let swiftlyExecutable = swiftlyRoot.appending(path: "bin/swiftly")
            try makeFastTrackExecutable(at: swiftlyExecutable)
            let sdkIdentifier = sdkIdentifier(
                for: SwiftVersion(major: 6, minor: 2, patch: 1)
            )
            try FileManager.default.createDirectory(
                at: swiftlyRoot.appending(path: "swift-sdks/\(sdkIdentifier).artifactbundle"),
                withIntermediateDirectories: true
            )
            let storage = EnvironmentStorage.directory(swiftlyRoot)
            let scratch = packageRoot.deletingLastPathComponent().appending(path: "scratch")
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
                environmentStorage: storage
            )
            let inherited = ProcessInfo.processInfo.environment
            _ = try await kit.build(
                packageRoot,
                product: nil,
                for: .linux(.x86_64),
                configuration: .release,
                scratchStorage: .directory(scratch),
                onEvent: nil
            )

            let commands = await runner.commands
            #expect(commands.count == 4)
            #expect(commands.allSatisfy {
                normalizedPath(URL(filePath: $0.environment?["SWIFTLY_HOME_DIR"] ?? ""))
                    == normalizedPath(swiftlyRoot)
            })
            #expect(commands.allSatisfy {
                normalizedPath(URL(filePath: $0.environment?["SWIFTLY_BIN_DIR"] ?? ""))
                    == normalizedPath(swiftlyRoot.appending(path: "bin"))
            })
            #expect(commands.allSatisfy {
                normalizedPath(URL(filePath: $0.environment?["SWIFTLY_TOOLCHAINS_DIR"] ?? ""))
                    == normalizedPath(swiftlyRoot.appending(path: "toolchains"))
            })
            #expect(commands.allSatisfy { $0.environment?["PATH"] == inherited["PATH"] })
            #expect(commands.allSatisfy { $0.environment?["HOME"] == inherited["HOME"] })
            #expect(commands.allSatisfy {
                $0.environment?["DEVELOPER_DIR"] == inherited["DEVELOPER_DIR"]
            })
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

            #expect(result.executable == executable)
            #expect(result.resourceBundles.isEmpty)
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
            let traits = try SwiftPMTraits(["RetryFeature"], includingDefaults: true)
            let scratch = packageRoot.appending(path: "scratch")
            let cache = packageRoot.appending(path: "cache")
            let configuration = packageRoot.appending(path: "configuration")
            let security = packageRoot.appending(path: "security")
            let sharedStorage = SwiftPMSharedStorage(
                cacheDirectory: cache,
                configurationDirectory: configuration,
                securityDirectory: security
            )

            let result = try await kit.build(
                packageRoot,
                product: nil,
                for: .linux(.x86_64),
                configuration: .release,
                scratchStorage: .directory(scratch),
                swiftPMTraits: traits,
                swiftPMSharedStorage: sharedStorage,
                onEvent: nil
            )

            #expect(result.executable == executable)
            #expect(result.resourceBundles.isEmpty)
            let commands = await runner.commands
            #expect(commands[3].arguments.contains("resolve"))
            #expect(commands.count == 7)
            #expect(commands.allSatisfy { $0.arguments.contains("--traits") })
            #expect(commands.allSatisfy { $0.arguments.contains("RetryFeature,default") })
            for command in commands {
                #expect(
                    normalizedPath(URL(filePath: try argument(after: "--cache-path", in: command.arguments)))
                        == normalizedPath(cache)
                )
                #expect(
                    normalizedPath(URL(filePath: try argument(after: "--config-path", in: command.arguments)))
                        == normalizedPath(configuration)
                )
                #expect(
                    normalizedPath(URL(filePath: try argument(after: "--security-path", in: command.arguments)))
                        == normalizedPath(security)
                )
            }
            #expect(
                normalizedPath(URL(filePath: try argument(after: "--scratch-path", in: commands[2].arguments)))
                    == normalizedPath(scratch)
            )
            #expect(
                normalizedPath(URL(filePath: try argument(after: "--scratch-path", in: commands[3].arguments)))
                    == normalizedPath(scratch)
            )
            #expect(
                normalizedPath(URL(filePath: try argument(after: "--scratch-path", in: commands[5].arguments)))
                    == normalizedPath(scratch)
            )
            #expect(
                normalizedPath(URL(filePath: try argument(after: "--scratch-path", in: commands[6].arguments)))
                    == normalizedPath(scratch)
            )
        }
    }

    @Test("The fast track forwards custom storage, published output, and cleanup")
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
                jobs: 2,
                scratchStorage: .directory(scratch),
                output: .publish(to: output, replacingExisting: true, cleanup: .reset),
                swiftPMTraits: try SwiftPMTraits(["PublishFeature"], includingDefaults: false),
                onEvent: nil
            )

            #expect(result.executable == output.appending(path: "Tool"))
            #expect(result.resourceBundles.isEmpty)
            let commands = await runner.commands
            #expect(commands.count == 5)
            let buildScratchOption = try #require(commands[2].arguments.firstIndex(of: "--scratch-path"))
            let buildScratchArgument = try #require(commands[2].arguments.dropFirst(buildScratchOption + 1).first)
            #expect(URL(filePath: buildScratchArgument).pathComponents == scratch.pathComponents)
            #expect(try argument(after: "--jobs", in: commands[2].arguments) == "2")
            #expect(try argument(after: "--traits", in: commands[2].arguments) == "PublishFeature")
            #expect(commands[4].arguments.contains("reset"))
            #expect(try argument(after: "--traits", in: commands[4].arguments) == "PublishFeature")
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
                output: .publish(to: output),
                strip: true,
                onEvent: nil
            )

            #expect(result.executable == output.appending(path: "Tool"))
            #expect(result.resourceBundles.isEmpty)
            #expect(try Data(contentsOf: executable) == originalBytes)
            let commands = await runner.commands
            #expect(commands.count == 5)
            #expect(commands[4].arguments.prefix(3) == ["run", "llvm-objcopy", "--strip-all"])
            #expect(commands[4].arguments[3] != executable.path(percentEncoded: false))
        }
    }

    @Test("The fast track propagates recorder errors unchanged")
    func recorderRefusalIsUnchanged() async throws {

        try await withFastTrackTemporaryDirectory { packageRoot in
            let runner = RecordingSubprocessRunner(results: [])
            let kit = fastTrackKit(packageRoot: packageRoot, runner: runner, installed: false)

            await #expect(throws: FastTrackRecorderRefusal.self) {
                try await kit.build(
                    packageRoot,
                    product: nil,
                    for: .linux(.x86_64),
                    configuration: .release,
                    recordRemovalPlan: { _ in throw FastTrackRecorderRefusal() },
                    onEvent: nil
                )
            }
            #expect(await runner.commands.isEmpty)
        }
    }

}

private func fastTrackKit(
    packageRoot: URL,
    runner: RecordingSubprocessRunner,
    versions: [SwiftVersion] = [SwiftVersion(major: 6, minor: 2, patch: 1)],
    installed: Bool = true,
    environmentStorage: EnvironmentStorage = .standard
) -> SwiftlyKit {

    let swiftlyURL: URL = switch environmentStorage {
        case .standard:
            packageRoot.appending(path: "swiftly")
        case .directory(let root):
            root.appending(path: "bin/swiftly")
    }
    let swiftly = SwiftlyInstallation(executableURL: swiftlyURL)
    let inventory = InstalledEnvironmentInventory(
        toolchains: installed ? versions : [],
        sdks: installed ? versions.map { version in
            InstalledStaticLinuxSDK(
                toolchainVersion: version,
                identifier: sdkIdentifier(for: version)
            )
        } : []
    )
    let releases = versions.map { version in
        OfficialStableRelease(
            version: version,
            staticLinuxSDK: StaticLinuxSDK(
                identifier: sdkIdentifier(for: version),
                version: "1.0.0"
            ),
            staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
                downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                checksum: String(repeating: "a", count: 64),
                supportedArchitectures: [.x86_64]
            )!
        )
    }

    return SwiftlyKit(
        assessor: EnvironmentAssessor(
            environmentStorage: environmentStorage,
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

private func makeFastTrackExecutable(at url: URL) throws {

    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path(percentEncoded: false)
    )
}

private func sdkIdentifier(for version: SwiftVersion) -> String {
    "swift-\(version)-RELEASE_static-linux-1.0.0"
}

private func argument(after option: String, in arguments: [String]) throws -> String {
    let optionIndex = try #require(arguments.firstIndex(of: option))
    return try #require(arguments.dropFirst(optionIndex + 1).first)
}

private func normalizedPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    let normalized = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
}

private func withFastTrackTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {

    try await withTemporaryDirectory(prefix: "SwiftlyKit-FastTrack") { directory in
        try Data("// swift-tools-version: 6.0\n".utf8).write(to: directory.appending(path: "Package.swift"))
        return try await body(directory)
    }
}

private struct FastTrackRecorderRefusal: Error {

}
