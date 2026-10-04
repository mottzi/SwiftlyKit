import Foundation

/// Executes exact SwiftPM command workflows.
struct SwiftPM {

    let runner: any SubprocessRunning

    let activeHostSDK: @Sendable ([String: String]) async throws -> HostSDK

    let hostSDKAlternatives: @Sendable (HostSDK) throws -> [HostSDK]

    let validateEnvironment: @Sendable (LocalBuildEnvironment) throws -> Void

    let sourceRoots: @Sendable (
        LocalBuildEnvironment,
        SwiftPMScratchDirectory,
        SwiftlyKitEvent.Handler?
    ) async throws -> [URL]

    init() {
        let runner = LiveSubprocessRunner()
        self.activeHostSDK = { try await HostSDKDiscovery().active(in: $0) }
        self.hostSDKAlternatives = { try HostSDKDiscovery().alternatives(to: $0) }
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
        ) async throws -> [URL],
        hostSDKAlternatives: @escaping @Sendable (HostSDK) throws -> [HostSDK] = {
            try HostSDKDiscovery().alternatives(to: $0)
        },
        activeHostSDK: @escaping @Sendable ([String: String]) async throws -> HostSDK = {
            try await HostSDKDiscovery().active(in: $0)
        }
    ) {
        self.activeHostSDK = activeHostSDK
        self.hostSDKAlternatives = hostSDKAlternatives
        self.runner = runner
        self.validateEnvironment = validateEnvironment
        self.sourceRoots = { environment, scratchDirectory, _ in
            try await sourceRoots(environment, scratchDirectory)
        }
    }

}

extension SwiftPM {

    func report(_ operation: OperationProgress.Operation, detail: String, to handler: SwiftlyKitEvent.Handler?) async {

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
