import Foundation

/// A prepared capability that binds build operations to one package, target, Swiftly executable, toolchain, and SDK.
public struct LocalBuildEnvironment: Sendable {

    /// The exact Swift toolchain version that is bound to build operations.
    public let swiftVersion: SwiftVersion

    /// The exact Static Linux SDK that is bound to build operations.
    public let staticLinuxSDK: StaticLinuxSDK

    let packageRoot: URL
    let swiftly: SwiftlyInstallation
    let sdkBundleURL: URL
    let target: BuildTarget

    init(
        swiftVersion: SwiftVersion,
        staticLinuxSDK: StaticLinuxSDK,
        packageRoot: URL,
        swiftly: SwiftlyInstallation,
        sdkBundleURL: URL,
        target: BuildTarget
    ) {
        self.swiftVersion = swiftVersion
        self.staticLinuxSDK = staticLinuxSDK
        self.packageRoot = packageRoot
        self.swiftly = swiftly
        self.sdkBundleURL = sdkBundleURL
        self.target = target
    }

}
