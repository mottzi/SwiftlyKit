import Foundation

extension BuildRuntimeBackend {
    
    func build(
        _ request: BuildRequest,
        using environment: BuildRuntimeEnvironment,
        onOutput: BuildRuntimeOutputHandler? = nil
    ) async throws -> URL {
        
        try validate(environment)
        guard request.target == .linux(environment.architecture) else {
            throw BuildRuntimeError.invalidEnvironment
        }
        let description = try await packageDescription(in: request.packageRoot, using: environment)
        guard description.products.contains(request.product) else {
            throw BuildRuntimeError.executableNotFound(request.product.name)
        }
        guard !description.requiresResources(request.product.name) else {
            throw BuildRuntimeError.unsupportedProductResources(request.product.name)
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
                    workingDirectory: request.packageRoot,
                    additions: request.environment
                ),
                onOutput: onOutput
            )
            guard buildResult.succeeded else {
                let diagnostic = boundedDiagnostic(buildResult)
                if indicatesRequiredResolution(diagnostic) {
                    throw BuildRuntimeError.dependencyResolutionRequired
                }
                throw BuildRuntimeError.commandFailed(operation: "build", diagnostic: diagnostic)
            }
            
            let pathResult = try await runner.run(
                command(
                    environment,
                    swiftArguments: ["build"] + commonArguments + ["--show-bin-path"],
                    workingDirectory: request.packageRoot,
                    additions: request.environment
                ),
                onOutput: nil
            )
            guard pathResult.succeeded else {
                throw BuildRuntimeError.commandFailed(
                    operation: "locating build output",
                    diagnostic: boundedDiagnostic(pathResult)
                )
            }
            let binaryDirectory = pathResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !binaryDirectory.isEmpty else {
                throw BuildRuntimeError.executableNotFound(request.product.name)
            }
            let binaryDirectoryURL = URL(filePath: binaryDirectory)
            if try containsRuntimeResourceBundle(in: binaryDirectoryURL) {
                throw BuildRuntimeError.unsupportedProductResources(request.product.name)
            }
            let executable = binaryDirectoryURL.appending(path: request.product.name)
            guard FileManager.default.fileExists(atPath: executable.path) else {
                throw BuildRuntimeError.executableNotFound(request.product.name)
            }
            try verifier.verify(executable, architecture: environment.architecture)
            
            if request.strip {
                try await strip(
                    executable,
                    for: request,
                    using: environment,
                    onOutput: onOutput
                )
            }
            
            if let output = request.output { return try publisher.publish(executable, to: output) }
            return executable
        }
    }
    
    private func strip(
        _ executable: URL,
        for request: BuildRequest,
        using environment: BuildRuntimeEnvironment,
        onOutput: BuildRuntimeOutputHandler?
    ) async throws {
        
        let result = try await runner.run(
            command(
                environment,
                tool: "llvm-objcopy",
                toolArguments: ["--strip-all", executable.path],
                workingDirectory: request.packageRoot,
                additions: request.environment
            ),
            onOutput: onOutput
        )
        guard result.succeeded else {
            throw BuildRuntimeError.commandFailed(
                operation: "stripping",
                diagnostic: boundedDiagnostic(result)
            )
        }
        try verifier.verify(executable, architecture: environment.architecture)
    }
    
    private func buildArguments(
        _ request: BuildRequest,
        environment: BuildRuntimeEnvironment,
        sdkSearchDirectory: URL
    ) -> [String] {
        
        var arguments = [
            "--package-path", request.packageRoot.path,
            "--disable-automatic-resolution",
            "--swift-sdks-path", sdkSearchDirectory.path,
            "--swift-sdk", environment.sdkID,
            "--product", request.product.name,
            "--configuration", request.configuration.runtimeName
        ]
        if let scratchDirectory = request.scratchDirectory {
            arguments += ["--scratch-path", scratchDirectory.path]
        }
        return arguments
    }
    
    private func withExactSDKSearchDirectory<T: Sendable>(
        _ environment: BuildRuntimeEnvironment,
        body: (URL) async throws -> T
    ) async throws -> T {
        
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SwiftlyKit-SDK-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: environment.sdkArtifactBundle.lastPathComponent),
            withDestinationURL: environment.sdkArtifactBundle
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
        } catch let error as BuildRuntimeError {
            throw error
        } catch {
            throw BuildRuntimeError.invalidExecutable("The build output could not be inspected for runtime resources.")
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
