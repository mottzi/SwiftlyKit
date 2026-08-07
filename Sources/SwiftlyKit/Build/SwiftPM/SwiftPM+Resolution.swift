import Foundation

extension SwiftPM {
    
    func resolveDependencies(
        using environment: LocalBuildEnvironment,
        onEvent: EventHandler? = nil
    ) async throws {
        
        try validateEnvironment(environment)
        let runtimeEnvironment = environment.swiftPMEnvironment
        await onEvent?(.progress(OperationProgress(
            operation: .resolvingDependencies,
            detail: "Resolving package dependencies."
        )))
        let result = try await runner.run(
            command(
                runtimeEnvironment,
                swiftArguments: ["package", "--package-path", environment.packageRoot.path, "resolve"],
                workingDirectory: environment.packageRoot
            ),
            onOutput: outputHandler(onEvent)
        )
        guard result.succeeded else {
            throw SwiftPMError.commandFailed(
                operation: .dependencyResolution,
                diagnostic: boundedDiagnostic(result)
            )
        }
    }
    
}
