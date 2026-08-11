import Foundation

struct SwiftPM {

    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()

    private(set) var validateEnvironment: @Sendable (LocalBuildEnvironment) throws -> Void = {
        try SwiftPM.liveValidateEnvironment($0)
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
            locateSDK: { SDKBundleLocator.locate(identifier: $0) }
        )
    }

}
