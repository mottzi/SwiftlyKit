import Foundation

extension SwiftPM {
    
    func build(
        _ request: BuildRequest,
        using environment: LocalBuildEnvironment,
        onEvent: EventHandler? = nil
    ) async throws -> URL {
        
        try validateEnvironment(environment)
        
        await report(.building, detail: "Building \(request.product.name).", to: onEvent)
        
        let description = try await packageDescription(using: environment)
        
        guard description.products.contains(request.product)
        else { throw SwiftPMError.executableNotFound(request.product.name) }
        
        guard !description.requiresResources(request.product.name)
        else { throw SwiftPMError.unsupportedProductResources(request.product.name) }
        
        return try await withExactSDKSearchDirectory(environment) { sdkSearchDirectory in
            let commonArguments = Self.buildArguments(
                request,
                environment: environment,
                sdkSearchDirectory: sdkSearchDirectory
            )
            
            let buildCommand = command(
                environment,
                swiftArguments: ["build"] + commonArguments,
                additions: request.environment
            )
            
            let buildResult = try await runner.run(buildCommand, onOutput: CommandOutput.handler(for: onEvent))
            
            guard buildResult.succeeded else {
                let diagnostic = boundedDiagnostic(buildResult)
                if Self.indicatesRequiredResolution(diagnostic) { throw SwiftPMError.dependencyResolutionRequired }
                else { throw SwiftPMError.commandFailed(operation: .build, diagnostic: diagnostic) }
            }
            
            let pathCommand = command(
                environment,
                swiftArguments: ["build"] + commonArguments + ["--show-bin-path"],
                additions: request.environment
            )
            
            let pathResult = try await runner.run(pathCommand, onOutput: nil)
            
            guard pathResult.succeeded else {
                throw SwiftPMError.commandFailed(
                    operation: .build,
                    diagnostic: boundedDiagnostic(pathResult)
                )
            }
            
            let binaryDirectory = pathResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !binaryDirectory.isEmpty else { throw SwiftPMError.executableNotFound(request.product.name) }
            
            let binaryDirectoryURL = URL(filePath: binaryDirectory)
            let hasRuntimeResourceBundle = try containsRuntimeResourceBundle(in: binaryDirectoryURL)
            guard !hasRuntimeResourceBundle else { throw SwiftPMError.unsupportedProductResources(request.product.name) }
            
            let executable = binaryDirectoryURL.appending(path: request.product.name)
            guard FileManager.default.fileExists(atPath: executable.path)
            else { throw SwiftPMError.executableNotFound(request.product.name) }
            
            try ELFExecutableVerifier.verify(executable, architecture: environment.target.architecture)
            
            if request.strip {
                await report(.stripping, detail: "Stripping \(request.product.name).", to: onEvent)
                
                try await strip(
                    executable,
                    for: request,
                    using: environment,
                    onOutput: CommandOutput.handler(for: onEvent)
                )
            }
            
            if let output = request.output {
                await report(.publishing, detail: "Publishing \(request.product.name).", to: onEvent)
                
                return try AtomicOutputPublisher.publish(executable, to: output)
            }
            
            return executable
        }
    }
    
}

extension SwiftPM {

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

    private func containsRuntimeResourceBundle(in directory: URL) throws -> Bool {

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            return try contents.contains { url in
                guard url.pathExtension == "resources" else { return false }
                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
                return resourceValues.isDirectory == true
            }
        } catch {
            throw SwiftPMError.invalidExecutable("The build output could not be inspected for runtime resources.")
        }
    }

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

    private static func buildArguments(
        _ request: BuildRequest,
        environment: LocalBuildEnvironment,
        sdkSearchDirectory: URL
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

        if let scratchDirectory = request.scratchDirectory {
            arguments += ["--scratch-path", scratchDirectory.path]
        }

        return arguments
    }

    private static func indicatesRequiredResolution(_ diagnostic: String) -> Bool {

        let lowercased = diagnostic.lowercased()
        
        return lowercased.contains("package.resolved")
            || lowercased.contains("automatic resolution is disabled")
            || lowercased.contains("dependencies could not be resolved")
    }

}
