import Foundation

struct SwiftPM: Sendable {

    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()

    private(set) var validateEnvironment: @Sendable (LocalBuildEnvironment) throws -> Void = {
        try SwiftPM.validate($0)
    }

}

extension SwiftPM {

    func report(
        _ operation: OperationProgress.Operation,
        detail: String,
        to handler: EventHandler?
    ) async {

        await handler?(.progress(OperationProgress(operation: operation, detail: detail)))
    }

}

extension SwiftPM {

    static func validate(
        _ environment: LocalBuildEnvironment,
        locateSDK: (String) -> URL? = { SDKBundleLocator.locate(identifier: $0) }
    ) throws {

        let packageInputs = try PackageInputSnapshot.capture(at: environment.packageRoot)

        guard packageInputs.toolsVersion <= environment.swiftVersion
        else { throw SwiftlyKitError.unsupportedToolsVersion(packageInputs.toolsVersion) }

        guard FileManager.default.isExecutableFile(atPath: environment.swiftly.executableURL.path)
        else { throw SwiftlyKitError.incompatibleSwiftly }

        let locatedSDKBundleURL = locateSDK(environment.staticLinuxSDK.identifier)
        guard locatedSDKBundleURL == environment.sdkBundleURL else { throw SwiftlyKitError.staticLinuxSDKUnavailable }
    }

}
