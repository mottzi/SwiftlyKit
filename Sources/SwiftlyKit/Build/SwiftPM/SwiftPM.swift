import Foundation

struct SwiftPM: Sendable {

    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()

    private(set) var validateEnvironment: @Sendable (LocalBuildEnvironment) throws -> Void = {
        try SwiftPM.validate($0)
    }

}

extension SwiftPM {

    static func validate(
        _ environment: LocalBuildEnvironment,
        locateSDK: (String) -> URL? = { SDKBundleLocator.locate(identifier: $0) }
    ) throws {

        let requirements: PackageRequirements
        do { requirements = try PackageRequirements.load(at: environment.packageRoot) }
        catch let error as PackageRequirements.LoadingError { throw error.swiftlyKitError }

        guard requirements.toolsVersion <= environment.swiftVersion
        else { throw SwiftlyKitError.unsupportedToolsVersion(requirements.toolsVersion) }

        guard FileManager.default.isExecutableFile(atPath: environment.swiftlyExecutableURL.path)
        else { throw SwiftlyKitError.incompatibleSwiftly }

        let locatedSDKBundleURL = locateSDK(environment.staticLinuxSDK.identifier)
        guard locatedSDKBundleURL == environment.sdkBundleURL else { throw SwiftlyKitError.staticLinuxSDKUnavailable }
    }

}
