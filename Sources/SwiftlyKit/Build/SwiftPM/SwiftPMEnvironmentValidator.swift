import Foundation

enum SwiftPMEnvironmentValidator {

    static func validate(
        _ environment: LocalBuildEnvironment,
        locateSDK: (String) -> URL?
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
