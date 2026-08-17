import Foundation

/// Exact SwiftPM command workflows and their internal test seams.
struct SwiftPM {

    let runner: any SubprocessRunning

    let validateEnvironment: @Sendable (LocalBuildEnvironment) throws -> Void

    let sourceRoots: @Sendable (
        LocalBuildEnvironment,
        SwiftPMScratchDirectory,
        any SubprocessRunning
    ) async throws -> [URL]

    init() {
        runner = LiveSubprocessRunner()
        validateEnvironment = { try SwiftPM.liveValidateEnvironment($0) }
        sourceRoots = { environment, scratchDirectory, runner in
            try await SwiftPM.packageGraphSourceRoots(
                using: environment,
                scratchDirectory: scratchDirectory,
                runner: runner
            )
        }
    }

    init(
        runner: any SubprocessRunning,
        validateEnvironment: @escaping @Sendable (LocalBuildEnvironment) throws -> Void,
        sourceRoots: @escaping @Sendable (
            LocalBuildEnvironment,
            SwiftPMScratchDirectory,
            any SubprocessRunning
        ) async throws -> [URL] = { environment, _, _ in [environment.packageRoot] }
    ) {
        self.runner = runner
        self.validateEnvironment = validateEnvironment
        self.sourceRoots = sourceRoots
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
