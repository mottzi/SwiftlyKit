import Foundation

/// Executes exact SwiftPM command workflows.
struct SwiftPM {

    let runner: any SubprocessRunning

    let validateEnvironment: @Sendable (LocalBuildEnvironment) throws -> Void

    let sourceRoots: @Sendable (
        LocalBuildEnvironment,
        SwiftPMScratchDirectory,
        SwiftlyKitEvent.Handler?
    ) async throws -> [URL]

    init() {
        let runner = LiveSubprocessRunner()
        self.runner = runner
        validateEnvironment = { try SwiftPM.liveValidateEnvironment($0) }
        sourceRoots = { environment, scratchDirectory, onEvent in
            try await SwiftPM.packageGraphSourceRoots(
                using: environment,
                scratchDirectory: scratchDirectory,
                runner: runner,
                onEvent: onEvent
            )
        }
    }

    init(
        runner: any SubprocessRunning,
        validateEnvironment: @escaping @Sendable (LocalBuildEnvironment) throws -> Void,
        sourceRoots: @escaping @Sendable (
            LocalBuildEnvironment,
            SwiftPMScratchDirectory
        ) async throws -> [URL]
    ) {
        self.runner = runner
        self.validateEnvironment = validateEnvironment
        self.sourceRoots = { environment, scratchDirectory, _ in
            try await sourceRoots(environment, scratchDirectory)
        }
    }

}

extension SwiftPM {

    func report(
        _ operation: OperationProgress.Operation,
        detail: String,
        to handler: SwiftlyKitEvent.Handler?
    ) async {

        await handler?(.progress(OperationProgress(operation: operation, detail: detail)))
    }

}

extension SwiftPM {

    private static func liveValidateEnvironment(_ environment: LocalBuildEnvironment) throws {
        try SwiftPMEnvironmentValidator.validate(
            environment,
            locateSDK: { identifier in
                SDKBundleLocator.locate(identifier: identifier, in: environment.environmentStorage)
            }
        )
    }

}
