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
            (.packageChangedDuringBuild, .packageChangedDuringBuild),
            (
                .packageSourceStabilityUnavailable("unavailable"),
                .packageSourceStabilityUnavailable("unavailable")
            ),
            (.executableNotFound("Tool"), .executableProductNotFound("Tool")),
            (.runtimeResourceVerificationFailed, .runtimeResourceVerificationFailed),
            (.invalidExecutable("invalid"), .executableVerificationFailed("invalid")),
            (.unsafeBuildStorage(output), .unsafeBuildStorage(output)),
            (.unsafeSwiftPMSharedStorage(output), .unsafeSwiftPMSharedStorage(output)),
            (.outputInsideBuildStorage(output), .outputInsideBuildStorage(output)),
            (.outputAlreadyExists(output), .outputAlreadyExists(output)),
            (.outputPublicationFailed(output), .outputPublicationFailed(output)),
            (
                .postBuildCleanupFailed(output: output, diagnostic: "cleanup failed"),
                .postBuildCleanupFailed(output: output, detail: "cleanup failed")
            ),
            (.commandFailed(operation: .building, diagnostic: "build failed"), .buildFailed("build failed")),
            (
                .commandFailed(operation: .inspectingPackage, diagnostic: "invalid manifest"),
                .packageInspectionFailed("invalid manifest")
            ),
            (
                .commandFailed(operation: .resolvingDependencies, diagnostic: "unresolved"),
                .dependencyResolutionFailed("unresolved")
            ),
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
    func exactBuildCommand(mapping: (configuration: BuildConfiguration, argument: String)) async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n")
            ])
            let values = try SwiftPMEnvironment([
                "CUSTOM": .plain("value")
            ])
            let snapshot = values.snapshot(inheriting: [
                "HOME": "/trusted/home",
                "SWIFTLY_HOME_DIR": "/trusted/swiftly-home",
                "SWIFTLY_TOOLCHAINS_DIR": "/trusted/toolchains"
            ])
            let sharedRoot = directory.deletingLastPathComponent()
                .appending(path: "SwiftlyKit-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
            let sharedStorage = SwiftPMSharedStorage(
                cacheDirectory: sharedRoot.appending(path: "cache", directoryHint: .isDirectory),
                configurationDirectory: sharedRoot.appending(path: "configuration", directoryHint: .isDirectory),
                securityDirectory: sharedRoot.appending(path: "security", directoryHint: .isDirectory)
            )
            defer { try? FileManager.default.removeItem(at: sharedRoot) }
            let environment = buildEnvironment(
                in: directory,
                swiftPMEnvironment: snapshot,
                swiftPMTraits: try SwiftPMTraits(["Beta", "Alpha"], includingDefaults: true),
                swiftPMSharedStorage: sharedStorage
            )
            let scratch = directory.appending(path: "scratch")
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                configuration: mapping.configuration,
                jobs: 3,
                scratchStorage: .directory(scratch)
            )

            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            let result = try await swiftPM.build(request, using: environment)
            #expect(result.executable == executable)
            #expect(result.resourceBundles.isEmpty)
            #expect(result.directory.pathComponents == directory.pathComponents)
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
            #expect(build.arguments.contains(scratch.path(percentEncoded: false)))
            #expect(try argument(after: "--jobs", in: build.arguments) == "3")
            #expect(build.environment?["CUSTOM"] == "value")
            #expect(build.environment?["HOME"] == "/trusted/home")
            #expect(build.environment?["SWIFTLY_HOME_DIR"] == "/trusted/swiftly-home")
            #expect(build.environment?["SWIFTLY_TOOLCHAINS_DIR"] == "/trusted/toolchains")
            #expect(build.environment?["SWIFTLY_BIN_DIR"] == "/")
            #expect(commands[0].environment?["CUSTOM"] == "value")
            #expect(try argument(after: "--traits", in: commands[0].arguments) == "Alpha,Beta,default")
            #expect(try argument(after: "--traits", in: commands[1].arguments) == "Alpha,Beta,default")
            #expect(try argument(after: "--traits", in: commands[2].arguments) == "Alpha,Beta,default")
            let dumpIndex = try #require(commands[0].arguments.firstIndex(of: "dump-package"))
            let dumpTraitsIndex = try #require(commands[0].arguments.firstIndex(of: "--traits"))
            #expect(dumpTraitsIndex < dumpIndex)
            #expect(commands[2].environment?["CUSTOM"] == "value")
            #expect(commands[2].arguments.contains("--show-bin-path"))
            #expect(try argument(after: "--jobs", in: commands[2].arguments) == "3")

            for command in commands {
                #expect(normalizedPath(try argument(after: "--cache-path", in: command.arguments))
                    == normalizedPath(sharedRoot.appending(path: "cache").path(percentEncoded: false)))
                #expect(normalizedPath(try argument(after: "--config-path", in: command.arguments))
                    == normalizedPath(sharedRoot.appending(path: "configuration").path(percentEncoded: false)))
                #expect(normalizedPath(try argument(after: "--security-path", in: command.arguments))
                    == normalizedPath(sharedRoot.appending(path: "security").path(percentEncoded: false)))
            }

            let packageIndex = try #require(commands[0].arguments.firstIndex(of: "package"))
            let packageCacheIndex = try #require(commands[0].arguments.firstIndex(of: "--cache-path"))
            #expect(packageIndex < packageCacheIndex)
            #expect(packageCacheIndex < dumpIndex)

            let buildIndex = try #require(commands[1].arguments.firstIndex(of: "build"))
            let buildCacheIndex = try #require(commands[1].arguments.firstIndex(of: "--cache-path"))
            #expect(buildIndex < buildCacheIndex)
            let showBinPathIndex = try #require(commands[2].arguments.firstIndex(of: "--show-bin-path"))
            let showBinPathCacheIndex = try #require(commands[2].arguments.firstIndex(of: "--cache-path"))
            #expect(showBinPathCacheIndex < showBinPathIndex)
        }
    }

    @Test("Package-default scratch storage remains valid inside the package")
    func packageDefaultScratchStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n")
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            let result = try await swiftPM.build(
                BuildRequest(ExecutableProduct(name: "Tool")),
                using: buildEnvironment(in: directory)
            )

            #expect(result.executable == executable)
            let commands = await runner.commands
            #expect(commands.count == 3)
            #expect(commands.allSatisfy { !$0.arguments.contains("--scratch-path") })
        }
    }

    @Test("Every selected-tool command uses the same custom environment namespace")
    func customEnvironmentStorageEnvironment() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let packageRoot = directory.appending(path: "package")
            try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: false)
            let scratch = directory.deletingLastPathComponent().appending(path: "scratch")
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n")
            ])
            let swiftlyRoot = directory.appending(path: "swiftly")
            let swiftlyExecutable = swiftlyRoot.appending(path: "bin/swiftly")
            try makeSwiftPMTestExecutable(at: swiftlyExecutable)
            let detectedSwiftly = try await SwiftlyInstallation.detect(storage: .directory(swiftlyRoot))
            let swiftly = try #require(detectedSwiftly)
            let inherited = SwiftPMEnvironment.inherited.snapshot(inheriting: [
                "PATH": "/trusted/path",
                "HOME": "/trusted/home",
                "DEVELOPER_DIR": "/trusted/developer-dir",
                "SWIFTLY_HOME_DIR": "/ambient/home",
                "SWIFTLY_BIN_DIR": "/ambient/bin",
                "SWIFTLY_TOOLCHAINS_DIR": "/ambient/toolchains"
            ])
            let environment = buildEnvironment(
                in: packageRoot,
                swiftPMEnvironment: inherited,
                swiftly: swiftly,
                environmentStorage: .directory(swiftlyRoot)
            )

            _ = try await SwiftPM(runner: runner, validateEnvironment: { _ in }).build(
                BuildRequest(
                    ExecutableProduct(name: "Tool"),
                    scratchStorage: .directory(scratch)
                ),
                using: environment
            )

            let commands = await runner.commands
            #expect(commands.allSatisfy {
                guard let value = $0.environment?["SWIFTLY_HOME_DIR"] else { return false }
                return normalizedPath(value) == normalizedPath(swiftlyRoot.path(percentEncoded: false))
            })
            #expect(commands.allSatisfy {
                guard let value = $0.environment?["SWIFTLY_BIN_DIR"] else { return false }
                return normalizedPath(value) == normalizedPath(
                    swiftlyRoot.appending(path: "bin").path(percentEncoded: false)
                )
            })
            #expect(commands.allSatisfy {
                guard let value = $0.environment?["SWIFTLY_TOOLCHAINS_DIR"] else { return false }
                return normalizedPath(value) == normalizedPath(
                    swiftlyRoot.appending(path: "toolchains").path(percentEncoded: false)
                )
            })
            #expect(commands.allSatisfy { $0.environment?["PATH"] == "/trusted/path" })
            #expect(commands.allSatisfy { $0.environment?["HOME"] == "/trusted/home" })
            #expect(commands.allSatisfy {
                $0.environment?["DEVELOPER_DIR"] == "/trusted/developer-dir"
            })
            let sdkSelectionCommands = commands.filter {
                $0.arguments.contains("--swift-sdks-path")
            }
            #expect(sdkSelectionCommands.count == 2)
            for command in sdkSelectionCommands {
                let selectedSDKPath = try argument(after: "--swift-sdks-path", in: command.arguments)
                #expect(URL(filePath: selectedSDKPath).pathComponents.starts(with: scratch.pathComponents))
                #expect(normalizedPath(selectedSDKPath) != normalizedPath(
                    swiftlyRoot.appending(path: "swift-sdks").path(percentEncoded: false)
                ))
            }
        }
    }

    @Test("Standard shared storage leaves SwiftPM shared-location flags unset")
    func standardSharedStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"]))
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            _ = try await swiftPM.executableProducts(using: buildEnvironment(in: directory))

            let command = try #require(await runner.commands.first)
            let arguments = command.arguments
            for option in ["--cache-path", "--config-path", "--security-path"] {
                #expect(!arguments.contains(option))
            }
        }
    }

    @Test("Partial shared storage emits only the selected SwiftPM location flag")
    func partialSharedStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let cache = directory.deletingLastPathComponent()
                .appending(path: "SwiftlyKit-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: cache) }
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"]))
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })
            let environment = buildEnvironment(
                in: directory,
                swiftPMSharedStorage: SwiftPMSharedStorage(cacheDirectory: cache)
            )

            _ = try await swiftPM.executableProducts(using: environment)

            let command = try #require(await runner.commands.first)
            let arguments = command.arguments
            #expect(normalizedPath(try argument(after: "--cache-path", in: arguments))
                == normalizedPath(cache.path(percentEncoded: false)))
            #expect(!arguments.contains("--config-path"))
            #expect(!arguments.contains("--security-path"))
            let packageIndex = try #require(arguments.firstIndex(of: "package"))
            let dumpIndex = try #require(arguments.firstIndex(of: "dump-package"))
            let cacheIndex = try #require(arguments.firstIndex(of: "--cache-path"))
            #expect(packageIndex < cacheIndex)
            #expect(cacheIndex < dumpIndex)
        }
    }

    @Test("A default build leaves concurrent job selection to SwiftPM")
    func defaultBuildJobs() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n")
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            _ = try await swiftPM.build(
                BuildRequest(ExecutableProduct(name: "Tool")),
                using: buildEnvironment(in: directory)
            )

            let commands = await runner.commands
            #expect(!commands[1].arguments.contains("--jobs"))
            #expect(!commands[2].arguments.contains("--jobs"))
            for command in commands {
                #expect(!command.arguments.contains("--cache-path"))
                #expect(!command.arguments.contains("--config-path"))
                #expect(!command.arguments.contains("--security-path"))
            }
        }
    }

    @Test(
        "A nonpositive build job count fails before running commands",
        arguments: [0, -1]
    )
    func invalidBuildJobs(jobs: Int) async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let runner = RecordingSubprocessRunner(results: [])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            await #expect(throws: SwiftlyKitError.invalidBuildJobCount(jobs)) {
                try await swiftPM.build(
                    BuildRequest(ExecutableProduct(name: "Tool"), jobs: jobs),
                    using: buildEnvironment(in: directory)
                )
            }

            #expect(await runner.commands.isEmpty)
        }
    }

    @Test("A scratch directory overlapping shared SwiftPM storage fails before a subprocess")
    func rejectsScratchSharedStorageOverlap() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let runner = RecordingSubprocessRunner(results: [])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })
            let sharedStorage = try SwiftPMSharedStorage(cacheDirectory: scratch).validated()
            let environment = buildEnvironment(
                in: directory,
                swiftPMSharedStorage: sharedStorage
            )

            await #expect(throws: SwiftPMError.self) {
                try await swiftPM.build(
                    BuildRequest(
                        ExecutableProduct(name: "Tool"),
                        scratchStorage: .directory(scratch)
                    ),
                    using: environment
                )
            }

            #expect(await runner.commands.isEmpty)
        }
    }

    @Test(
        "Environment storage rejects overlap before running a build command",
        arguments: EnvironmentStorageOverlap.allCases
    )
    func rejectsEnvironmentStorageOverlap(overlap: EnvironmentStorageOverlap) async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let packageRoot = directory.appending(path: "package")
            try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: false)
            let root = directory.appending(path: "swiftly")
            let expectedRoot = try CanonicalFileURL.resolve(root).standardizedFileURL
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let scratchOutsidePackage = directory.appending(path: "scratch")
            let (scratch, shared, output) = switch overlap {
                case .scratch:
                    (SwiftPMScratchStorage.directory(root), SwiftPMSharedStorage.standard, BuildOutput.buildStorage)
                case .shared:
                    (
                        SwiftPMScratchStorage.directory(scratchOutsidePackage),
                        SwiftPMSharedStorage(cacheDirectory: root),
                        BuildOutput.buildStorage
                    )
                case .publication:
                    (
                        SwiftPMScratchStorage.directory(scratchOutsidePackage),
                        SwiftPMSharedStorage.standard,
                        BuildOutput.publish(to: root)
                    )
            }
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n")
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })
            let environment = buildEnvironment(
                in: packageRoot,
                swiftPMSharedStorage: shared,
                environmentStorage: .directory(root)
            )

            await #expect(throws: SwiftPMError.unsafeEnvironmentStorage(expectedRoot)) {
                try await swiftPM.build(
                    BuildRequest(
                        ExecutableProduct(name: "Tool"),
                        scratchStorage: scratch,
                        output: output
                    ),
                    using: environment
                )
            }
            #expect(await runner.commands.isEmpty)
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
                    .success(output: directory.path(percentEncoded: false) + "\n"),
                    .success(output: packageJSON),
                    .success(output: "second build"),
                    .success(output: directory.path(percentEncoded: false) + "\n")
                ]
            )
            let scratch = directory.appending(path: "scratch", directoryHint: .isDirectory)
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                configuration: .release,
                scratchStorage: .directory(scratch)
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
            #expect(URL(filePath: firstPath).pathComponents.starts(with: scratch.pathComponents))
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
                    .success(output: directory.path(percentEncoded: false) + "\n")
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
                    .hasPrefix(directory.appending(path: ".build").path(percentEncoded: false) + "/")
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

    @Test("A source mutation withholds published output and reports a typed failure")
    func sourceMutationWithholdsOutput() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let source = directory.appending(path: "Sources/Tool/main.swift")
            let executable = directory.appending(path: "Tool")
            let output = directory.appending(path: "PublishedTool")
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("print(1)\n".utf8).write(to: source)
            try writeELF(to: executable, architecture: .arm64)
            let runner = RecordingSubprocessRunner(
                results: [
                    .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                    .success(output: "built"),
                    .success(output: directory.path(percentEncoded: false) + "\n")
                ],
                onRun: { command in
                    guard command.arguments.contains("build"),
                          !command.arguments.contains("--show-bin-path")
                    else { return }
                    try Data("print(2)\n".utf8).write(to: source)
                }
            )
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            await #expect(throws: SwiftPMError.packageChangedDuringBuild) {
                try await swiftPM.build(
                    BuildRequest(
                        ExecutableProduct(name: "Tool"),
                        output: .publish(to: output)
                    ),
                    using: buildEnvironment(in: directory)
                )
            }

            #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        }
    }

    @Test("Unobservable source fails closed before compilation")
    func sourceObservationFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let outside = directory.deletingLastPathComponent().appending(path: UUID().uuidString)
            try Data("outside".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(
                at: directory.appending(path: "escaping-source"),
                withDestinationURL: outside
            )
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"]))
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            await #expect(throws: SwiftPMError.packageSourceStabilityUnavailable(
                "A package-source symbolic link resolves outside the observed package roots."
            )) {
                try await swiftPM.build(
                    BuildRequest(ExecutableProduct(name: "Tool")),
                    using: buildEnvironment(in: directory)
                )
            }

            #expect(await runner.commands.count == 1)
        }
    }

    @Test("A local dependency mutation rejects the build result")
    func localDependencyMutation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let dependency = directory.deletingLastPathComponent().appending(
                path: "SwiftlyKit-LocalDependency-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: dependency) }
            let dependencySource = dependency.appending(path: "source.swift")
            let executable = directory.appending(path: "Tool")
            try Data("let value = 1\n".utf8).write(to: dependencySource)
            try writeELF(to: executable, architecture: .arm64)
            let runner = RecordingSubprocessRunner(
                results: [
                    .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                    .success(output: "built"),
                    .success(output: directory.path(percentEncoded: false) + "\n")
                ],
                onRun: { command in
                    guard command.arguments.contains("build"),
                          !command.arguments.contains("--show-bin-path")
                    else { return }
                    try Data("let value = 2\n".utf8).write(to: dependencySource)
                }
            )
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in },
                sourceRoots: { environment, _, _ in [environment.packageRoot, dependency] }
            )

            await #expect(throws: SwiftPMError.packageChangedDuringBuild) {
                try await swiftPM.build(
                    BuildRequest(ExecutableProduct(name: "Tool")),
                    using: buildEnvironment(in: directory)
                )
            }
        }
    }

    @Test("Build storage returns the executable beside linked dependency resources")
    func transitiveResources() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let resources = directory.appending(path: "Dependency_Assets.resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            try Data("asset".utf8).write(to: resources.appending(path: "asset.txt"))
            _ = try createBundleForSwiftPMTest(named: "Unrelated_Stale.resources", in: directory)
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            try createSwiftPMResourceMetadata(
                product: "Tool",
                module: "Dependency",
                bundle: resources.lastPathComponent,
                in: directory
            )
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n")
            ])
            let environment = buildEnvironment(in: directory)
            let request = BuildRequest(ExecutableProduct(name: "Tool"))
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            let result = try await swiftPM.build(request, using: environment)
            #expect(result.executable == executable)
            #expect(result.resourceBundles.map(\.pathComponents) == [resources.pathComponents])
            #expect(result.directory.pathComponents == directory.pathComponents)
            #expect(try Data(contentsOf: resources.appending(path: "asset.txt")) == Data("asset".utf8))
        }
    }

    @Test("Build storage retains linked privacy-only resource bundles")
    func privacyMetadataResources() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let resources = directory.appending(path: "Dependency_Metadata.resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            try Data("privacy metadata".utf8).write(to: resources.appending(path: "PrivacyInfo.xcprivacy"))
            try createSwiftPMResourceMetadata(
                product: "Tool",
                module: "Dependency",
                bundle: resources.lastPathComponent,
                in: directory
            )
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n")
            ])
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            let result = try await swiftPM.build(
                BuildRequest(ExecutableProduct(name: "Tool")),
                using: buildEnvironment(in: directory)
            )
            #expect(result.executable == executable)
            #expect(result.resourceBundles.map(\.pathComponents) == [resources.pathComponents])
        }
    }

    @Test("Publication returns the complete exact build result")
    func publishesResources() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let resources = directory.appending(path: "Dependency_Assets.resources", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            try Data("asset".utf8).write(to: resources.appending(path: "asset.txt"))
            _ = try createBundleForSwiftPMTest(named: "Unrelated_Stale.resources", in: directory)
            try createSwiftPMResourceMetadata(
                product: "Tool",
                module: "Dependency",
                bundle: resources.lastPathComponent,
                in: directory
            )
            let publication = directory.appending(path: "Published", directoryHint: .isDirectory)
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n")
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            let result = try await swiftPM.build(
                BuildRequest(
                    ExecutableProduct(name: "Tool"),
                    output: .publish(to: publication)
                ),
                using: buildEnvironment(in: directory)
            )

            #expect(result.executable == publication.appending(path: "Tool"))
            #expect(result.resourceBundles == [
                publication.appending(path: "Dependency_Assets.resources", directoryHint: .isDirectory)
            ])
            #expect(result.directory == publication)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: publication.path())) == [
                "Tool",
                "Dependency_Assets.resources"
            ])
        }
    }

    @Test("Dependency resolution uses the exact toolchain and forwards progress and command output")
    func dependencyResolutionCommandAndEvents() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let runner = RecordingSubprocessRunner(results: [
                .success(output: "resolved", standardError: "warning")
            ])
            let events = SwiftPMEventRecorder()
            let values = try SwiftPMEnvironment(["RESOLUTION_VALUE": .plain("enabled")])
            let environment = buildEnvironment(
                in: directory,
                swiftPMEnvironment: values.snapshot(inheriting: [:]),
                swiftPMTraits: .all
            )
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            try await swiftPM.resolveDependencies(
                in: .packageDefault,
                using: environment,
                onEvent: { await events.record($0) }
            )

            let commands = await runner.commands
            #expect(commands.count == 1)
            #expect(commands[0].arguments == [
                "run", "swift", "package", "--enable-all-traits", "resolve", "+6.2.1"
            ])
            #expect(commands[0].workingDirectory == directory)
            #expect(commands[0].environment?["RESOLUTION_VALUE"] == "enabled")
            #expect(!commands[0].arguments.contains("--scratch-path"))
            #expect(!commands[0].arguments.contains("--cache-path"))
            #expect(!commands[0].arguments.contains("--config-path"))
            #expect(!commands[0].arguments.contains("--security-path"))
            #expect(await events.operations == [.resolvingDependencies])
            let observedCommand = try #require(await events.commands.first)
            #expect(observedCommand.executable == commands[0].executableURL)
            #expect(observedCommand.arguments == commands[0].arguments)
            #expect(observedCommand.workingDirectory == commands[0].workingDirectory)
            #expect(observedCommand.environment == commands[0].environment)
            #expect(await events.outputs == [
                EventOutput(stream: .standardOutput, text: "resolved"),
                EventOutput(stream: .standardError, text: "warning")
            ])
        }
    }

    @Test("Dependency resolution forwards explicit scratch and shared SwiftPM storage")
    func dependencyResolutionStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let scratch = directory.appending(path: "resolution-scratch", directoryHint: .isDirectory)
            let sharedRoot = directory.deletingLastPathComponent()
                .appending(path: "SwiftlyKit-resolution-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
            let sharedStorage = SwiftPMSharedStorage(
                cacheDirectory: sharedRoot.appending(path: "cache", directoryHint: .isDirectory),
                configurationDirectory: sharedRoot.appending(path: "configuration", directoryHint: .isDirectory),
                securityDirectory: sharedRoot.appending(path: "security", directoryHint: .isDirectory)
            )
            defer { try? FileManager.default.removeItem(at: sharedRoot) }
            let runner = RecordingSubprocessRunner(results: [.success(output: "resolved")])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })
            let environment = buildEnvironment(
                in: directory,
                swiftPMTraits: .none,
                swiftPMSharedStorage: sharedStorage
            )

            try await swiftPM.resolveDependencies(
                in: .directory(scratch),
                using: environment
            )

            let command = try #require(await runner.commands.first)
            let arguments = command.arguments
            let packageIndex = try #require(arguments.firstIndex(of: "package"))
            let resolveIndex = try #require(arguments.firstIndex(of: "resolve"))
            for option in ["--cache-path", "--config-path", "--security-path", "--scratch-path"] {
                let optionIndex = try #require(arguments.firstIndex(of: option))
                #expect(packageIndex < optionIndex)
                #expect(optionIndex < resolveIndex)
            }
            #expect(normalizedPath(try argument(after: "--cache-path", in: arguments))
                == normalizedPath(sharedRoot.appending(path: "cache").path(percentEncoded: false)))
            #expect(normalizedPath(try argument(after: "--config-path", in: arguments))
                == normalizedPath(sharedRoot.appending(path: "configuration").path(percentEncoded: false)))
            #expect(normalizedPath(try argument(after: "--security-path", in: arguments))
                == normalizedPath(sharedRoot.appending(path: "security").path(percentEncoded: false)))
            #expect(normalizedPath(try argument(after: "--scratch-path", in: arguments))
                == normalizedPath(scratch.path(percentEncoded: false)))
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
                try await swiftPM.resolveDependencies(
                    in: .packageDefault,
                    using: buildEnvironment(in: directory)
                )
            }
        }
    }

    @Test("Explicit stripping prepares staged publication and preserves build storage")
    func stripAndPublish() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            let output = directory.appending(path: "PublishedTool")
            try writeELF(to: executable, architecture: .arm64)
            try Data("previous output".utf8).write(to: output)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n"),
                .success(output: "stripped")
            ])
            let events = SwiftPMEventRecorder()
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                configuration: .release,
                output: .publish(to: output, replacingExisting: true),
                strip: true
            )
            let values = try SwiftPMEnvironment([
                "BUILD_SECRET": .sensitive("private")
            ])
            let sharedRoot = directory.deletingLastPathComponent()
                .appending(path: "SwiftlyKit-strip-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
            let sharedStorage = SwiftPMSharedStorage(
                cacheDirectory: sharedRoot.appending(path: "cache", directoryHint: .isDirectory),
                configurationDirectory: sharedRoot.appending(path: "configuration", directoryHint: .isDirectory),
                securityDirectory: sharedRoot.appending(path: "security", directoryHint: .isDirectory)
            )
            defer { try? FileManager.default.removeItem(at: sharedRoot) }
            let environment = buildEnvironment(
                in: directory,
                swiftPMEnvironment: values.snapshot(inheriting: ["BASE": "value"]),
                swiftPMTraits: try SwiftPMTraits(["StripFeature"], includingDefaults: false),
                swiftPMSharedStorage: sharedStorage
            )
            let swiftPM = SwiftPM(
                runner: runner,
                validateEnvironment: { _ in }
            )

            let result = try await swiftPM.build(
                request,
                using: environment,
                onEvent: { await events.record($0) }
            )

            let publishedExecutable = output.appending(path: "Tool")
            #expect(result.executable == publishedExecutable)
            #expect(result.resourceBundles.isEmpty)
            #expect(try Data(contentsOf: publishedExecutable) == Data(contentsOf: executable))
            let commands = await runner.commands
            #expect(commands.count == 4)
            let strippedExecutable = commands[3].arguments[3]
            #expect(commands[3].arguments.prefix(3) == ["run", "llvm-objcopy", "--strip-all"])
            #expect(commands[3].arguments.suffix(1) == ["+6.2.1"])
            #expect(strippedExecutable != executable.path(percentEncoded: false))
            #expect(strippedExecutable != publishedExecutable.path(percentEncoded: false))
            #expect(strippedExecutable.hasPrefix(directory.path(percentEncoded: false) + "/.PublishedTool.swiftlykit-"))
            #expect(!FileManager.default.fileExists(atPath: strippedExecutable))
            #expect(commands[0...2].allSatisfy { $0.environment?["BUILD_SECRET"] == "private" })
            #expect(commands[0...2].allSatisfy { $0.sensitiveEnvironmentKeys == ["BUILD_SECRET"] })
            #expect(commands[3].environment?["BUILD_SECRET"] == nil)
            #expect(commands[3].environment?["BASE"] == "value")
            #expect(commands[3].sensitiveEnvironmentKeys.isEmpty)
            #expect(!commands[3].arguments.contains("--traits"))
            #expect(!commands[3].arguments.contains("StripFeature"))
            let observedCommands = await events.commands
            #expect(observedCommands.count == commands.count)
            for (observed, command) in zip(observedCommands, commands) {
                #expect(observed.executable == command.executableURL)
                #expect(observed.arguments == command.arguments)
                #expect(observed.workingDirectory == command.workingDirectory)
            }
            #expect(observedCommands[0].environment?["BASE"] == "value")
            #expect(observedCommands[0].environment?["BUILD_SECRET"] == "<redacted>")
            #expect(observedCommands[1].environment?["BUILD_SECRET"] == "<redacted>")
            #expect(observedCommands[2].environment?["BUILD_SECRET"] == "<redacted>")
            #expect(observedCommands[3].environment?["BASE"] == "value")
            #expect(observedCommands[3].environment?["BUILD_SECRET"] == nil)
            #expect(observedCommands[0].environment?.values.allSatisfy { $0 != "private" } == true)
            #expect(observedCommands[1].environment?.values.allSatisfy { $0 != "private" } == true)
            #expect(observedCommands[2].environment?.values.allSatisfy { $0 != "private" } == true)
            #expect(observedCommands[3].environment?.values.allSatisfy { $0 != "private" } == true)
            for option in ["--cache-path", "--config-path", "--security-path"] {
                #expect(commands[0].arguments.contains(option))
                #expect(commands[1].arguments.contains(option))
                #expect(commands[2].arguments.contains(option))
                #expect(!commands[3].arguments.contains(option))
            }
            #expect(await events.operations == [.building, .stripping, .publishing])
            #expect(await events.outputs == [
                EventOutput(stream: .standardOutput, text: "built"),
                EventOutput(stream: .standardOutput, text: "stripped")
            ])
            #expect(await events.sequence == [
                .progress,
                .command,
                .command,
                .output,
                .command,
                .progress,
                .command,
                .output,
                .progress
            ])
        }
    }

    @Test("Published output refuses replacement by default")
    func publicationRefusesReplacementByDefault() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            let output = directory.appending(path: "PublishedTool")
            try writeELF(to: executable, architecture: .arm64)
            let publishedBytes = Data("previous output".utf8)
            try publishedBytes.write(to: output)
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n")
            ])
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            await #expect(throws: SwiftPMError.outputAlreadyExists(output)) {
                try await swiftPM.build(
                    BuildRequest(
                        ExecutableProduct(name: "Tool"),
                        output: .publish(to: output)
                    ),
                    using: buildEnvironment(in: directory)
                )
            }

            #expect(try Data(contentsOf: output) == publishedBytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).allSatisfy {
                !$0.hasPrefix(".PublishedTool.swiftlykit-")
            })
        }
    }

    @Test("Stripped build-storage output leaves the SwiftPM executable unchanged")
    func stripInBuildStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let executable = directory.appending(path: "Tool")
            let strippedExecutable = directory.appending(path: ".Tool.swiftlykit-stripped")
            try writeELF(to: executable, architecture: .arm64)
            let resources = directory.appending(path: "Dependency_Assets.resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            try createSwiftPMResourceMetadata(
                product: "Tool",
                module: "Dependency",
                bundle: resources.lastPathComponent,
                in: directory
            )
            let originalBytes = try Data(contentsOf: executable)
            let packageJSON = try packageDescriptionJSON(executableProducts: ["Tool"])
            let runner = RecordingSubprocessRunner(results: [
                .success(output: packageJSON),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n"),
                .success(output: "stripped")
            ])
            let events = SwiftPMEventRecorder()
            let swiftPM = SwiftPM(runner: runner, validateEnvironment: { _ in })

            let result = try await swiftPM.build(
                BuildRequest(ExecutableProduct(name: "Tool"), strip: true),
                using: buildEnvironment(in: directory),
                onEvent: { await events.record($0) }
            )

            #expect(result.executable == strippedExecutable)
            #expect(result.resourceBundles.map(\.pathComponents) == [resources.pathComponents])
            #expect(try Data(contentsOf: executable) == originalBytes)
            #expect(try Data(contentsOf: strippedExecutable) == originalBytes)
            let commands = await runner.commands
            #expect(commands.count == 4)
            #expect(commands[3].arguments[3] != executable.path(percentEncoded: false))
            #expect(commands[3].arguments[3] != strippedExecutable.path(percentEncoded: false))
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
            let publishedBytes = Data("previous output".utf8)
            try publishedBytes.write(to: output)
            let runner = RecordingSubprocessRunner(results: [
                .success(output: try packageDescriptionJSON(executableProducts: ["Tool"])),
                .success(output: "built"),
                .success(output: directory.path(percentEncoded: false) + "\n"),
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
                        output: .publish(to: output, replacingExisting: true),
                        strip: true
                    ),
                    using: buildEnvironment(in: directory)
                )
            }

            #expect(try Data(contentsOf: executable) == originalBytes)
            #expect(try Data(contentsOf: output) == publishedBytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).allSatisfy {
                !$0.hasPrefix(".PublishedTool.swiftlykit-")
            })
        }
    }

}

enum EnvironmentStorageOverlap: String, CaseIterable, Sendable {

    case scratch
    case shared
    case publication

}

private func createBundleForSwiftPMTest(named name: String, in directory: URL) throws -> URL {

    let bundle = directory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    return bundle
}

private func createSwiftPMResourceMetadata(product: String, module: String, bundle: String, in directory: URL) throws {

    let productDirectory = directory.appending(path: "\(product).product", directoryHint: .isDirectory)
    let buildDirectory = directory.appending(path: "\(module).build", directoryHint: .isDirectory)
    let derivedSources = buildDirectory.appending(path: "DerivedSources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: productDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: derivedSources, withIntermediateDirectories: true)

    let object = buildDirectory.appending(path: "resource_bundle_accessor.swift.o")
    try Data().write(to: object)
    try Data(object.path(percentEncoded: false).utf8).write(
        to: productDirectory.appending(path: "Objects.LinkFileList")
    )

    let source = """
    let mainPath = Bundle.main.bundleURL.appendingPathComponent("\(bundle)").path
    let buildPath = "\(directory.appending(path: bundle).path(percentEncoded: false))"
    """
    try Data(source.utf8).write(
        to: derivedSources.appending(path: "resource_bundle_accessor.swift")
    )
}

private func buildEnvironment(
    in directory: URL,
    swiftPMEnvironment: SwiftPMEnvironment.Snapshot = SwiftPMEnvironment.inherited.snapshot(),
    swiftPMTraits: SwiftPMTraits = .packageDefaults,
    swiftPMSharedStorage: SwiftPMSharedStorage = .standard,
    swiftly: SwiftlyInstallation? = nil,
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
        swiftly: swiftly ?? SwiftlyInstallation(executableURL: swiftlyURL),
        sdkBundleURL: directory.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64),
        swiftPMEnvironment: swiftPMEnvironment,
        swiftPMTraits: swiftPMTraits,
        swiftPMSharedStorage: swiftPMSharedStorage,
        environmentStorage: environmentStorage
    )
}

private func makeSwiftPMTestExecutable(at url: URL) throws {

    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nprintf '1.2.3\\n'\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path(percentEncoded: false)
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

private struct EventOutput: Equatable {

    let stream: CommandOutputChunk.Stream
    let text: String

}

private enum EventKind: Equatable {

    case progress
    case command
    case output

}

private actor SwiftPMEventRecorder {

    private(set) var operations: [OperationProgress.Operation] = []
    private(set) var details: [String] = []
    private(set) var commands: [CommandInvocation] = []
    private(set) var outputs: [EventOutput] = []
    private(set) var sequence: [EventKind] = []

    func record(_ event: SwiftlyKitEvent) {
        switch event {
            case .progress(let progress):
                operations.append(progress.operation)
                details.append(progress.detail)
                sequence.append(.progress)
            case .command(let command):
                commands.append(command)
                sequence.append(.command)
            case .output(let output):
                outputs.append(EventOutput(stream: output.stream, text: output.text))
                sequence.append(.output)
        }
    }

}
