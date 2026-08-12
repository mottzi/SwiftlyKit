import Foundation

extension SwiftPM {
    
    func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws -> URL {
        
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
        
        guard !description.requiresRuntimeResources(request.product.name)
        else { throw SwiftPMError.unsupportedProductResources(request.product.name) }
        
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

        let buildCommand = command(
            environment,
            swiftArguments: ["build"] + commonArguments,
            additions: request.environment
        )

        let buildResult = try await runner.run(buildCommand, onOutput: CommandOutputChunk.handler(for: onEvent))

        guard buildResult.succeeded else {
            let diagnostic = boundedDiagnostic(buildResult)
            if Self.indicatesRequiredResolution(diagnostic) { throw SwiftPMError.dependencyResolutionRequired }
            else { throw SwiftPMError.commandFailed(operation: .building, diagnostic: diagnostic) }
        }

        let pathCommand = command(
            environment,
            swiftArguments: ["build"] + commonArguments + ["--show-bin-path"],
            additions: request.environment
        )

        let pathResult = try await runner.run(pathCommand, onOutput: nil)

        guard pathResult.succeeded
        else { throw SwiftPMError.commandFailed(operation: .building, diagnostic: boundedDiagnostic(pathResult)) }

        let binaryDirectory = pathResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !binaryDirectory.isEmpty else { throw SwiftPMError.executableNotFound(request.product.name) }

        let binaryDirectoryURL = URL(filePath: binaryDirectory)
        
        let runtimeResourceBundles: [String]
        do {
            runtimeResourceBundles = try BuildOutputInspector.runtimeResourceBundles(in: binaryDirectoryURL)
        } catch {
            throw SwiftPMError.invalidExecutable("The build output could not be inspected for runtime resources.")
        }

        guard runtimeResourceBundles.isEmpty else {
            let names = runtimeResourceBundles.joined(separator: ", ")
            await report(.building, detail: "Build produced unsupported runtime resource bundles: \(names).", to: onEvent)
            throw SwiftPMError.unsupportedProductResources(request.product.name)
        }

        let executable = binaryDirectoryURL.appending(path: request.product.name)
        guard FileManager.default.fileExists(atPath: executable.path)
        else { throw SwiftPMError.executableNotFound(request.product.name) }

        try ELFExecutableVerifier.verify(executable, architecture: environment.target.architecture)

        switch request.output {
            case .buildStorage:
                guard request.strip else { return executable }

                await report(.stripping, detail: "Stripping \(request.product.name).", to: onEvent)
                return try await AtomicOutputCopier.copy(
                    executable,
                    to: Self.strippedBuildStorageExecutable(for: executable),
                    replacingExisting: true,
                    prepare: { stagedExecutable in
                        try await strip(
                            stagedExecutable,
                            for: request,
                            using: environment,
                            onOutput: CommandOutputChunk.handler(for: onEvent)
                        )
                    }
                )

            case .copy(let destination, let cleanup):
                let output: URL

                if request.strip {
                    await report(.stripping, detail: "Stripping \(request.product.name).", to: onEvent)
                    output = try await AtomicOutputCopier.copy(
                        executable,
                        to: destination,
                        prepare: { stagedExecutable in
                            try await strip(
                                stagedExecutable,
                                for: request,
                                using: environment,
                                onOutput: CommandOutputChunk.handler(for: onEvent)
                            )
                            await report(.copying, detail: "Copying \(request.product.name).", to: onEvent)
                        }
                    )
                } else {
                    await report(.copying, detail: "Copying \(request.product.name).", to: onEvent)
                    output = try await AtomicOutputCopier.copy(executable, to: destination)
                }

                do {
                    try await perform(cleanup, in: request.storage, using: environment, onEvent: onEvent)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as SwiftPMError {
                    throw SwiftPMError.postBuildCleanupFailed(
                        output: output,
                        diagnostic: error.cleanupDiagnostic
                    )
                } catch {
                    throw SwiftPMError.postBuildCleanupFailed(
                        output: output,
                        diagnostic: "An unexpected cleanup error occurred."
                    )
                }

                return output
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

        let stripCommand = command(
            environment,
            tool: "llvm-objcopy",
            toolArguments: ["--strip-all", executable.path],
            additions: request.environment
        )

        let result = try await runner.run(stripCommand, onOutput: onOutput)

        guard result.succeeded
        else { throw SwiftPMError.commandFailed(operation: .stripping, diagnostic: boundedDiagnostic(result)) }

        try ELFExecutableVerifier.verify(executable, architecture: environment.target.architecture)
    }

}

extension SwiftPM {

    private static func validate(_ output: BuildOutput, outside scratchDirectory: URL) throws {

        guard case .copy(let destination, let cleanup) = output,
              cleanup != .retain
        else { return }

        let resolvedScratchDirectory = scratchDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = destination
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appending(path: destination.lastPathComponent)
            .standardizedFileURL

        guard resolvedDestination != resolvedScratchDirectory,
              !resolvedDestination.path.hasPrefix(resolvedScratchDirectory.path + "/")
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
            "--swift-sdks-path", sdkSearchDirectory.path,
            "--swift-sdk", environment.target.architecture.swiftSDKSelector,
            "--product", request.product.name,
            "--configuration", configurationArgument
        ]

        if scratchDirectory.isExplicit {
            arguments += ["--scratch-path", scratchDirectory.url.path]
        }

        return arguments
    }

    private static func indicatesRequiredResolution(_ diagnostic: String) -> Bool {

        let lowercased = diagnostic.lowercased()
        
        return lowercased.contains("package.resolved")
            || lowercased.contains("automatic resolution is disabled")
            || lowercased.contains("dependencies could not be resolved")
    }

    private static func strippedBuildStorageExecutable(for executable: URL) -> URL {
        executable
            .deletingLastPathComponent()
            .appending(path: ".\(executable.lastPathComponent).swiftlykit-stripped")
    }

}
