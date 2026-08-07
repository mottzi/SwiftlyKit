import Foundation

extension LocalBuildEnvironment {
    
    /// Revalidates the local capability before it is used for package work.
    func validate() throws {
        
        let requirements: PackageRequirements
        do {
            requirements = try PackageRequirements.load(at: packageRoot)
        } catch let error as PackageRequirements.LoadingError {
            throw error.swiftlyKitError
        }
        guard requirements.toolsVersion <= swiftVersion else {
            throw SwiftlyKitError.unsupportedToolsVersion(requirements.toolsVersion)
        }
        guard FileManager.default.isExecutableFile(atPath: swiftlyExecutableURL.path) else {
            throw SwiftlyKitError.incompatibleSwiftly
        }
        guard SDKBundleLocator.locate(identifier: staticLinuxSDK.identifier) == sdkBundleURL else {
            throw SwiftlyKitError.staticLinuxSDKUnavailable
        }
    }
    
    var swiftPMEnvironment: SwiftPMEnvironment {
        SwiftPMEnvironment(
            swiftlyExecutable: swiftlyExecutableURL,
            toolchainSelector: swiftVersion.description,
            sdkID: target.architecture.swiftSDKSelector,
            sdkArtifactBundle: sdkBundleURL,
            architecture: target.architecture
        )
    }
    
}
