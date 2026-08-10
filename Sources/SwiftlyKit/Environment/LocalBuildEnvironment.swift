import Foundation

/// A prepared capability binding operations to one exact toolchain and SDK.
public struct LocalBuildEnvironment: Sendable {

    public let swiftVersion: SwiftVersion
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
