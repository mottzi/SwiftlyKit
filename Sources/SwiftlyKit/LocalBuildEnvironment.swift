import Foundation

/// A prepared capability binding operations to one exact toolchain and SDK.
public struct LocalBuildEnvironment: Sendable {
    
    public let swiftVersion: SwiftVersion
    public let staticLinuxSDK: StaticLinuxSDK
    
    let swiftlyExecutableURL: URL
    let sdkBundleURL: URL
    let target: BuildTarget
    let toolsVersion: SwiftVersion
    
    init(
        swiftVersion: SwiftVersion,
        staticLinuxSDK: StaticLinuxSDK,
        swiftlyExecutableURL: URL,
        sdkBundleURL: URL,
        target: BuildTarget,
        toolsVersion: SwiftVersion
    ) {
        self.swiftVersion = swiftVersion
        self.staticLinuxSDK = staticLinuxSDK
        self.swiftlyExecutableURL = swiftlyExecutableURL
        self.sdkBundleURL = sdkBundleURL
        self.target = target
        self.toolsVersion = toolsVersion
    }
    
}
