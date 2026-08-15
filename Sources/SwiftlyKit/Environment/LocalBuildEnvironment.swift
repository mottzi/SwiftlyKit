import Foundation

/// A prepared capability that binds operations to one package, target, toolchain, SDK, and SwiftPM environment snapshot.
public struct LocalBuildEnvironment: Sendable {

    /// The exact Swift toolchain version that is bound to build operations.
    public let swiftVersion: SwiftVersion

    /// The exact Static Linux SDK that is bound to build operations.
    public let staticLinuxSDK: StaticLinuxSDK

    let packageRoot: URL
    let swiftly: SwiftlyInstallation
    let sdkBundleURL: URL
    let target: BuildTarget
    let swiftPMEnvironment: SwiftPMEnvironment.Snapshot

    init(
        swiftVersion: SwiftVersion,
        staticLinuxSDK: StaticLinuxSDK,
        packageRoot: URL,
        swiftly: SwiftlyInstallation,
        sdkBundleURL: URL,
        target: BuildTarget,
        swiftPMEnvironment: SwiftPMEnvironment.Snapshot
    ) {
        self.swiftVersion = swiftVersion
        self.staticLinuxSDK = staticLinuxSDK
        self.packageRoot = packageRoot
        self.swiftly = swiftly
        self.sdkBundleURL = sdkBundleURL
        self.target = target
        self.swiftPMEnvironment = swiftPMEnvironment
    }

}
