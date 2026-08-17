import Foundation

enum SwiftPMEnvironmentValidator {

    static func validate(_ environment: LocalBuildEnvironment, locateSDK: (String) -> URL?) throws {

        let packageInputs = try PackageInputSnapshot.capture(at: environment.packageRoot)
        _ = try environment.swiftPMSharedStorage.validated()
        try environment.environmentStorage.validateNotOverlapping(packageInputs.packageRoot)

        if let location = environment.swiftly.location {
            let expectedLocation = try environment.environmentStorage.resolved()
            guard location == expectedLocation else {
                throw SwiftlyKitError.incompatibleSwiftly
            }
        }

        guard packageInputs.toolsVersion <= environment.swiftVersion
        else { throw SwiftlyKitError.unsupportedToolsVersion(packageInputs.toolsVersion) }

        guard FileManager.default.isExecutableFile(atPath: environment.swiftly.executableURL.path(percentEncoded: false))
        else { throw SwiftlyKitError.incompatibleSwiftly }

        let locatedSDKBundleURL = locateSDK(environment.staticLinuxSDK.identifier)
        guard locatedSDKBundleURL == environment.sdkBundleURL else { throw SwiftlyKitError.staticLinuxSDKUnavailable }
    }

}
