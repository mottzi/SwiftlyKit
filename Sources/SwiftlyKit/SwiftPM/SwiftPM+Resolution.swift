import Foundation

extension SwiftPM {

    func resolveDependencies(
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {

        try validateEnvironment(environment)

        await report(
            .resolvingDependencies,
            detail: "Resolving package dependencies.",
            to: onEvent
        )

        let arguments = ["package"] + environment.swiftPMTraits.arguments + ["resolve"]
        let resolutionCommand = Self.command(
            environment,
            swiftArguments: arguments
        )

        let result = try await runner.run(resolutionCommand, onOutput: CommandOutputChunk.handler(for: onEvent))

        guard result.succeeded else {
            throw SwiftPMError.commandFailed(
                operation: .resolvingDependencies,
                diagnostic: Self.boundedDiagnostic(result)
            )
        }
    }

}
