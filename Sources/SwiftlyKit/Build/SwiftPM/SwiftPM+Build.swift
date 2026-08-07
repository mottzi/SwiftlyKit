import Foundation

extension SwiftPM {
    
    func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: EventHandler? = nil
    ) async throws -> URL {
        
        try validateEnvironment(environment)
        await onEvent?(.progress(OperationProgress(
            operation: .building,
            detail: "Building \(request.product.name)."
        )))
        let description = try await packageDescription(using: environment)
        guard description.products.contains(request.product) else {
            throw SwiftPMError.executableNotFound(request.product.name)
        }
        guard !description.requiresResources(request.product.name) else {
            throw SwiftPMError.unsupportedProductResources(request.product.name)
        }
        
        return try await withExactSDKSearchDirectory(environment) { sdkSearchDirectory in
            let commonArguments = buildArguments(
                request,
                environment: environment,
                sdkSearchDirectory: sdkSearchDirectory
            )
            let buildResult = try await runner.run(
                command(
                    environment,
                    swiftArguments: ["build"] + commonArguments,
                    workingDirectory: environment.packageRoot,
                    additions: request.environment
                ),
                onOutput: CommandOutput.handler(for: onEvent)
            )
            guard buildResult.succeeded else {
                let diagnostic = boundedDiagnostic(buildResult)
                if indicatesRequiredResolution(diagnostic) {
                    throw SwiftPMError.dependencyResolutionRequired
                }
                throw SwiftPMError.commandFailed(operation: .build, diagnostic: diagnostic)
            }
            
            let pathResult = try await runner.run(
                command(
                    environment,
                    swiftArguments: ["build"] + commonArguments + ["--show-bin-path"],
                    workingDirectory: environment.packageRoot,
                    additions: request.environment
                ),
                onOutput: nil
            )
            guard pathResult.succeeded else {
                throw SwiftPMError.commandFailed(
                    operation: .locatingBuildOutput,
                    diagnostic: boundedDiagnostic(pathResult)
                )
            }
            let binaryDirectory = pathResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !binaryDirectory.isEmpty else {
                throw SwiftPMError.executableNotFound(request.product.name)
            }
            let binaryDirectoryURL = URL(filePath: binaryDirectory)
            if try containsRuntimeResourceBundle(in: binaryDirectoryURL) {
                throw SwiftPMError.unsupportedProductResources(request.product.name)
            }
            let executable = binaryDirectoryURL.appending(path: request.product.name)
            guard FileManager.default.fileExists(atPath: executable.path) else {
                throw SwiftPMError.executableNotFound(request.product.name)
            }
            try ELFExecutableVerifier.verify(executable, architecture: environment.target.architecture)
            
            if request.strip {
                await onEvent?(.progress(OperationProgress(
                    operation: .stripping,
                    detail: "Stripping \(request.product.name)."
                )))
                try await strip(
                    executable,
                    for: request,
                    using: environment,
                    onOutput: CommandOutput.handler(for: onEvent)
                )
            }
            
            if let output = request.output {
                await onEvent?(.progress(OperationProgress(
                    operation: .publishing,
                    detail: "Publishing \(request.product.name)."
                )))
                return try AtomicOutputPublisher.publish(executable, to: output)
            }
            return executable
        }
    }
    
    private func strip(
        _ executable: URL,
        for request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onOutput: SubprocessOutputHandler?
    ) async throws {
        
        let result = try await runner.run(
            command(
                environment,
                tool: "llvm-objcopy",
                toolArguments: ["--strip-all", executable.path],
                workingDirectory: environment.packageRoot,
                additions: request.environment
            ),
            onOutput: onOutput
        )
        guard result.succeeded else {
            throw SwiftPMError.commandFailed(
                operation: .stripping,
                diagnostic: boundedDiagnostic(result)
            )
        }
        try ELFExecutableVerifier.verify(executable, architecture: environment.target.architecture)
    }
    
    private func buildArguments(
        _ request: BuildRequest,
        environment: LocalBuildEnvironment,
        sdkSearchDirectory: URL
    ) -> [String] {
        
        var arguments = [
            "--package-path", environment.packageRoot.path,
            "--disable-automatic-resolution",
            "--swift-sdks-path", sdkSearchDirectory.path,
            "--swift-sdk", environment.target.architecture.swiftSDKSelector,
            "--product", request.product.name,
            "--configuration", request.configuration.runtimeName
        ]
        if let scratchDirectory = request.scratchDirectory {
            arguments += ["--scratch-path", scratchDirectory.path]
        }
        return arguments
    }
    
    private func withExactSDKSearchDirectory<T: Sendable>(
        _ environment: LocalBuildEnvironment,
        body: (URL) async throws -> T
    ) async throws -> T {
        
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SwiftlyKit-SDK-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: environment.sdkBundleURL.lastPathComponent),
            withDestinationURL: environment.sdkBundleURL
        )
        return try await body(directory)
    }
    
    private func indicatesRequiredResolution(_ diagnostic: String) -> Bool {
        
        let lowercased = diagnostic.lowercased()
        return lowercased.contains("package.resolved")
            || lowercased.contains("automatic resolution is disabled")
            || lowercased.contains("dependencies could not be resolved")
    }
    
    private func containsRuntimeResourceBundle(in directory: URL) throws -> Bool {
        
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).contains { url in
                guard url.pathExtension == "resources" else { return false }
                return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            }
        } catch let error as SwiftPMError {
            throw error
        } catch {
            throw SwiftPMError.invalidExecutable("The build output could not be inspected for runtime resources.")
        }
    }
    
}

private extension BuildConfiguration {
    
    var runtimeName: String {
        switch self {
            case .debug: "debug"
            case .release: "release"
        }
    }
    
}
