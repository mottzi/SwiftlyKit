import Foundation

extension BuildRuntimeBackend {
    
    func resolveDependencies(
        in packageRoot: URL,
        using environment: BuildRuntimeEnvironment,
        onOutput: BuildRuntimeOutputHandler? = nil
    ) async throws {
        
        try validate(environment)
        let result = try await runner.run(
            command(
                environment,
                swiftArguments: ["package", "--package-path", packageRoot.path, "resolve"],
                workingDirectory: packageRoot
            ),
            onOutput: onOutput
        )
        guard result.succeeded else {
            throw BuildRuntimeError.commandFailed(
                operation: "dependency resolution",
                diagnostic: boundedDiagnostic(result)
            )
        }
    }
    
}
