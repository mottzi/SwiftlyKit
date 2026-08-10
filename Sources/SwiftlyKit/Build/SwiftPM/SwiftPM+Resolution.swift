import Foundation

extension SwiftPM {

    func resolveDependencies(using environment: LocalBuildEnvironment, onEvent: EventHandler? = nil) async throws {

        try validateEnvironment(environment)

        let progress = OperationProgress(
            operation: .resolvingDependencies,
            detail: "Resolving package dependencies."
        )

        await onEvent?(.progress(progress))

        let resolutionCommand = command(
            environment,
            swiftArguments: [
                "package",
                "--package-path", environment.packageRoot.path,
                "resolve"
            ]
        )

        let result = try await runner.run(resolutionCommand, onOutput: CommandOutput.handler(for: onEvent))

        guard result.succeeded
        else { throw SwiftPMError.commandFailed(operation: .dependencyResolution, diagnostic: boundedDiagnostic(result)) }
    }

}
