import Foundation

extension SwiftPM {

    func resolveDependencies(
        in scratchStorage: SwiftPMScratchStorage,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {

        try validateEnvironment(environment)

        let scratchDirectory = try SwiftPMScratchDirectory(
            storage: scratchStorage,
            packageRoot: environment.packageRoot,
            sharedStorage: environment.swiftPMSharedStorage,
            environmentStorage: environment.environmentStorage
        )

        await report(
            .resolvingDependencies,
            detail: "Resolving package dependencies.",
            to: onEvent
        )

        var arguments = ["package"] + environment.swiftPMTraits.arguments
        arguments += scratchDirectory.commandArguments
        arguments += ["resolve"]
        let resolutionCommand = Self.command(
            environment,
            swiftArguments: arguments
        )

        let result = try await runner.run(resolutionCommand, onEvent: onEvent)

        guard result.succeeded else {
            throw SwiftPMError.commandFailed(
                operation: .resolvingDependencies,
                diagnostic: Self.boundedDiagnostic(result)
            )
        }
    }

}
