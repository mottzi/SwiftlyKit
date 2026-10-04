import Foundation

/// A prepared capability that binds operations to one package, target, toolchain, SDK, and SwiftPM workflow configuration.
public struct LocalBuildEnvironment: Sendable {

    /// The exact Swift toolchain version that is bound to build operations.
    public let swiftVersion: SwiftVersion

    /// The exact Static Linux SDK that is bound to build operations.
    public let staticLinuxSDK: StaticLinuxSDK

    let hostSDK: HostSDK?

    let packageRoot: URL
    let swiftly: SwiftlyInstallation
    let sdkBundleURL: URL
    let target: BuildTarget
    let environmentStorage: EnvironmentStorage
    let swiftPMEnvironment: SwiftPMEnvironment.Snapshot
    let swiftPMTraits: SwiftPMTraits
    let swiftPMSharedStorage: SwiftPMSharedStorage

    init(
        swiftVersion: SwiftVersion,
        staticLinuxSDK: StaticLinuxSDK,
        packageRoot: URL,
        swiftly: SwiftlyInstallation,
        sdkBundleURL: URL,
        target: BuildTarget,
        swiftPMEnvironment: SwiftPMEnvironment.Snapshot,
        swiftPMTraits: SwiftPMTraits = .packageDefaults,
        swiftPMSharedStorage: SwiftPMSharedStorage = .standard,
        environmentStorage: EnvironmentStorage = .standard,
        hostSDK: HostSDK? = nil
    ) {
        self.hostSDK = hostSDK
        self.swiftVersion = swiftVersion
        self.staticLinuxSDK = staticLinuxSDK
        self.packageRoot = packageRoot
        self.swiftly = swiftly
        self.sdkBundleURL = sdkBundleURL
        self.target = target
        self.environmentStorage = environmentStorage
        self.swiftPMEnvironment = swiftPMEnvironment
        self.swiftPMTraits = swiftPMTraits
        self.swiftPMSharedStorage = swiftPMSharedStorage
    }

    /// The macOS SDK bound to host compilation, when prepared on a live host.
    public var hostSDKVersion: String? { hostSDK?.version }

}

extension LocalBuildEnvironment {

    /// Keeps all workflow choices while binding a validated host SDK context.
    func using(hostSDK: HostSDK) -> LocalBuildEnvironment {
        replacing(hostSDK: hostSDK, snapshot: swiftPMEnvironment)
    }

    func using(moduleCache: URL) -> LocalBuildEnvironment {
        var values = swiftPMEnvironment.values
        values["SWIFTPM_MODULECACHE_OVERRIDE"] = moduleCache.path(percentEncoded: false)
        values["CLANG_MODULE_CACHE_PATH"] = moduleCache.path(percentEncoded: false)
        let snapshot = SwiftPMEnvironment.Snapshot(
            values: values,
            sensitiveNames: swiftPMEnvironment.sensitiveNames,
            toolValues: swiftPMEnvironment.toolValues
        )
        return replacing(hostSDK: hostSDK, snapshot: snapshot)
    }

    private func replacing(hostSDK: HostSDK?, snapshot: SwiftPMEnvironment.Snapshot) -> LocalBuildEnvironment {
        LocalBuildEnvironment(
            swiftVersion: swiftVersion,
            staticLinuxSDK: staticLinuxSDK,
            packageRoot: packageRoot,
            swiftly: swiftly,
            sdkBundleURL: sdkBundleURL,
            target: target,
            swiftPMEnvironment: snapshot,
            swiftPMTraits: swiftPMTraits,
            swiftPMSharedStorage: swiftPMSharedStorage,
            environmentStorage: environmentStorage,
            hostSDK: hostSDK
        )
    }

}
