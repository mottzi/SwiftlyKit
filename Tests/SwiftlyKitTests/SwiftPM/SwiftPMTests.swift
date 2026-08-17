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
            (.outputInsideBuildStorage(output), .outputInsideBuildStorage(output)),
            (.outputAlreadyExists(output), .outputAlreadyExists(output)),
            (.outputPublicationFailed(output), .outputPublicationFailed(output)),
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
            let environment = buildEnvironment(
                in: directory,
                swiftPMEnvironment: snapshot,
                swiftPMTraits: try SwiftPMTraits(["Beta", "Alpha"], includingDefaults: true)
            )
            let scratch = directory.appending(path: "scratch")
            let request = BuildRequest(
                ExecutableProduct(name: "Tool"),
                configuration: mapping.configuration,
                jobs: 3,
                storage: .directory(scratch)
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
            let environment = buildEnvironment(
                in: directory,
                swiftPMEnvironment: values.snapshot(inheriting: ["BASE": "value"]),
                swiftPMTraits: try SwiftPMTraits(["StripFeature"], includingDefaults: false)
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
            #expect(await events.operations == [.building, .stripping, .publishing])
            #expect(await events.outputs == [
                EventOutput(stream: .standardOutput, text: "built"),
                EventOutput(stream: .standardOutput, text: "stripped")
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
    swiftPMTraits: SwiftPMTraits = .packageDefaults
) -> LocalBuildEnvironment {

    LocalBuildEnvironment(
        swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
    staticLinuxSDK: StaticLinuxSDK(
        identifier: "sdk",
        version: "1.0.0"
    ),
        packageRoot: directory,
        swiftly: SwiftlyInstallation(executableURL: URL(filePath: "/swiftly")),
        sdkBundleURL: directory.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64),
        swiftPMEnvironment: swiftPMEnvironment,
        swiftPMTraits: swiftPMTraits
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
