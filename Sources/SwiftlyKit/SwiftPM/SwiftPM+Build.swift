import Foundation

extension SwiftPM {
    
    func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> BuildResult {
        
        try request.validate()
        try validateEnvironment(environment)

        let scratchDirectory = try SwiftPMScratchDirectory(
            storage: request.storage,
            packageRoot: environment.packageRoot
        )

        try Self.validate(request.output, outside: scratchDirectory.url)
        
        await report(.building, detail: "Building \(request.product.name).", to: onEvent)
        
        let description = try await packageDescription(using: environment)
        
        guard description.products.contains(request.product)
        else { throw SwiftPMError.executableNotFound(request.product.name) }
        
        let roots = try await sourceRoots(environment, scratchDirectory, runner)
        let stability = try await Self.startSourceStability(
            roots: roots,
            scratchDirectory: scratchDirectory.url
        )
        defer { stability.cancel() }
        
        let sdkSearchDirectory: URL
        do {
            sdkSearchDirectory = try SDKSelectionDirectory.resolve(
                sdkIdentifier: environment.staticLinuxSDK.identifier,
                sdkBundleURL: environment.sdkBundleURL,
                scratchDirectory: scratchDirectory.url
            )
        } catch let error as SDKSelectionDirectory.Error {
            throw SwiftPMError.sdkSearchPathPreparationFailed(
                error.errorDescription ?? "The exact SDK search directory could not be prepared."
            )
        } catch {
            throw SwiftPMError.sdkSearchPathPreparationFailed(
                "The exact SDK search directory could not be prepared."
            )
        }

        let commonArguments = Self.buildArguments(
            request,
            environment: environment,
            sdkSearchDirectory: sdkSearchDirectory,
            scratchDirectory: scratchDirectory
        )

        let buildCommand = Self.command(
            environment,
            swiftArguments: ["build"] + commonArguments
        )

        let buildResult = try await runner.run(buildCommand, onOutput: CommandOutputChunk.handler(for: onEvent))

        guard buildResult.succeeded else {
            let diagnostic = Self.boundedDiagnostic(buildResult)
            if Self.indicatesRequiredResolution(diagnostic) { throw SwiftPMError.dependencyResolutionRequired }
            else { throw SwiftPMError.commandFailed(operation: .building, diagnostic: diagnostic) }
        }

        let pathCommand = Self.command(
            environment,
            swiftArguments: ["build"] + commonArguments + ["--show-bin-path"]
        )

        let pathResult = try await runner.run(pathCommand, onOutput: nil)

        guard pathResult.succeeded
        else { throw SwiftPMError.commandFailed(operation: .building, diagnostic: Self.boundedDiagnostic(pathResult)) }

        let binaryDirectory = pathResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !binaryDirectory.isEmpty else { throw SwiftPMError.executableNotFound(request.product.name) }

        let binaryDirectoryURL = URL(filePath: binaryDirectory)
        
        let output: SwiftPMBuildOutput
        do {
            output = try SwiftPMBuildOutput.inspect(
                product: request.product.name,
                in: binaryDirectoryURL
            )
        } catch let error as SwiftPMError {
            throw error
        } catch {
            throw SwiftPMError.runtimeResourceVerificationFailed
        }

        let executable = output.executable
        guard FileManager.default.fileExists(atPath: executable.path(percentEncoded: false))
        else { throw SwiftPMError.executableNotFound(request.product.name) }

        try ELFExecutableVerifier.verify(executable, architecture: environment.target.architecture)

        try await Self.finishSourceStability(stability)

        switch request.output {
            case .buildStorage:
                guard request.strip else {
                    return BuildResult(
                        executable: executable,
                        resourceBundles: output.resourceBundles
                    )
                }

                await report(.stripping, detail: "Stripping \(request.product.name).", to: onEvent)
                let strippedExecutable = try await AtomicOutputPublisher.replaceBuildStorageExecutable(
                    executable,
                    at: Self.strippedBuildStorageExecutable(for: executable),
                    prepare: { stagedExecutable in
                        try await strip(
                            stagedExecutable,
                            for: request,
                            using: environment,
                            onOutput: CommandOutputChunk.handler(for: onEvent)
                        )
                    }
                )
                return BuildResult(
                    executable: strippedExecutable,
                    resourceBundles: output.resourceBundles
                )

            case .publish(let destination, let replacingExisting, let cleanup):
                if request.strip {
                    await report(.stripping, detail: "Stripping \(request.product.name).", to: onEvent)
                }

                if !request.strip {
                    await report(.publishing, detail: "Publishing \(request.product.name).", to: onEvent)
                }
                let result = try await AtomicOutputPublisher.publish(
                    output,
                    to: destination,
                    replacingExisting: replacingExisting,
                    prepareExecutable: { stagedExecutable in
                        if request.strip {
                            try await strip(
                                stagedExecutable,
                                for: request,
                                using: environment,
                                onOutput: CommandOutputChunk.handler(for: onEvent)
                            )
                        }
                        try ELFExecutableVerifier.verify(
                            stagedExecutable,
                            architecture: environment.target.architecture
                        )
                        if request.strip {
                            await report(.publishing, detail: "Publishing \(request.product.name).", to: onEvent)
                        }
                    }
                )

                do {
                    try await perform(cleanup, in: request.storage, using: environment, onEvent: onEvent)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as SwiftPMError {
                    throw SwiftPMError.postBuildCleanupFailed(
                        output: destination,
                        diagnostic: error.cleanupDiagnostic
                    )
                } catch {
                    throw SwiftPMError.postBuildCleanupFailed(
                        output: destination,
                        diagnostic: "An unexpected cleanup error occurred."
                    )
                }

                return result
        }
    }

}

extension SwiftPM {

    private func strip(
        _ executable: URL,
        for request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onOutput: SubprocessOutputHandler?
    ) async throws {

        let stripCommand = Self.toolCommand(
            environment,
            tool: "llvm-objcopy",
            toolArguments: ["--strip-all", executable.path(percentEncoded: false)]
        )

        let result = try await runner.run(stripCommand, onOutput: onOutput)

        guard result.succeeded
        else { throw SwiftPMError.commandFailed(operation: .stripping, diagnostic: Self.boundedDiagnostic(result)) }

        try ELFExecutableVerifier.verify(executable, architecture: environment.target.architecture)
    }

}

extension SwiftPM {

    private static func validate(_ output: BuildOutput, outside scratchDirectory: URL) throws {

        guard case .publish(let destination, _, let cleanup) = output,
              cleanup != .retain
        else { return }

        let resolvedScratchDirectory = scratchDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = destination
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appending(path: destination.lastPathComponent)
            .standardizedFileURL

        guard !resolvedDestination.pathComponents.starts(
            with: resolvedScratchDirectory.pathComponents
        )
        else { throw SwiftPMError.outputInsideBuildStorage(destination) }
    }

    private static func buildArguments(
        _ request: BuildRequest,
        environment: LocalBuildEnvironment,
        sdkSearchDirectory: URL,
        scratchDirectory: SwiftPMScratchDirectory
    ) -> [String] {

        let configurationArgument = switch request.configuration {
            case .debug: "debug"
            case .release: "release"
        }

        var arguments = [
            "--disable-automatic-resolution",
            "--swift-sdks-path", sdkSearchDirectory.path(percentEncoded: false),
            "--swift-sdk", environment.target.architecture.swiftSDKSelector,
            "--product", request.product.name,
            "--configuration", configurationArgument
        ]

        if scratchDirectory.isExplicit {
            arguments += ["--scratch-path", scratchDirectory.url.path(percentEncoded: false)]
        }

        if let jobs = request.jobs {
            arguments += ["--jobs", String(jobs)]
        }

        arguments += environment.swiftPMTraits.arguments

        return arguments
    }

    private static func strippedBuildStorageExecutable(for executable: URL) -> URL {
        executable
            .deletingLastPathComponent()
            .appending(path: ".\(executable.lastPathComponent).swiftlykit-stripped")
    }

    private static func startSourceStability(
        roots: [URL],
        scratchDirectory: URL
    ) async throws -> PackageSourceStability {

        do {
            return try await PackageSourceStability.start(
                roots: roots,
                excluding: [scratchDirectory]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch PackageSourceStabilityError.sourceChanged {
            throw SwiftPMError.packageChangedDuringBuild
        } catch PackageSourceStabilityError.observationFailed(let detail) {
            throw SwiftPMError.packageSourceStabilityUnavailable(detail)
        }
    }

    private static func finishSourceStability(_ stability: PackageSourceStability) async throws {

        do { try await stability.finish() }
        catch is CancellationError { throw CancellationError() }
        catch PackageSourceStabilityError.sourceChanged { throw SwiftPMError.packageChangedDuringBuild }
        catch PackageSourceStabilityError.observationFailed(let detail) {
            throw SwiftPMError.packageSourceStabilityUnavailable(detail)
        }
    }

}
