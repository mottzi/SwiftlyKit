import Foundation

extension SwiftPM {

    func cleanBuildArtifacts(
        in storage: BuildStorage,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {
        try await perform(.clean, in: storage, using: environment, onEvent: onEvent)
    }

    func resetBuildStorage(
        in storage: BuildStorage,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler? = nil
    ) async throws {
        try await perform(.reset, in: storage, using: environment, onEvent: onEvent)
    }

}

extension SwiftPM {

    func perform(
        _ cleanup: BuildCleanup,
        in storage: BuildStorage,
        using environment: LocalBuildEnvironment,
        onEvent: SwiftlyKitEvent.Handler?
    ) async throws {

        guard cleanup != .retain else { return }

        let scratchDirectory = try SwiftPMScratchDirectory(
            storage: storage,
            packageRoot: environment.packageRoot
        )

        let operation: SwiftPMError.Operation
        let progress: OperationProgress.Operation
        let detail: String
        let subcommand: String

        switch cleanup {
            case .retain:
                return
            case .clean:
                operation = .cleaningBuildArtifacts
                progress = .cleaningBuildArtifacts
                detail = "Cleaning build artifacts."
                subcommand = "clean"
            case .reset:
                operation = .resettingBuildStorage
                progress = .resettingBuildStorage
                detail = "Resetting build storage."
                subcommand = "reset"
        }

        await report(progress, detail: detail, to: onEvent)

        let arguments = ["package"] + environment.swiftPMTraits.arguments + [
            "--scratch-path", scratchDirectory.url.path(percentEncoded: false),
            subcommand
        ]
        let cleanupCommand = Self.command(
            environment,
            swiftArguments: arguments
        )

        let result = try await runner.run(cleanupCommand, onOutput: CommandOutputChunk.handler(for: onEvent))

        guard result.succeeded else {
            throw SwiftPMError.commandFailed(operation: operation, diagnostic: Self.boundedDiagnostic(result))
        }
    }

}
