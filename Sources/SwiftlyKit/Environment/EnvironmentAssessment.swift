import Foundation

/// A read-only description of the exact environment SwiftlyKit will prepare.
public struct EnvironmentAssessment: Sendable {
    
    public let packageRoot: URL
    public let toolsVersion: SwiftVersion
    public let swiftVersion: SwiftVersion
    public let staticLinuxSDK: StaticLinuxSDK
    public let isSwiftlyAvailable: Bool
    public let isToolchainAvailable: Bool
    public let isStaticLinuxSDKAvailable: Bool
    public let requiredComponents: [PreparationComponent]
    
    let target: BuildTarget
    let swiftVersionPreference: String?
    let swiftVersionFileURL: URL?
    let swiftlyExecutableURL: URL?
    let sdkDownloadURL: URL
    let sdkChecksum: String
    let sdkBundleURL: URL?
    let manifestContents: Data
    let swiftVersionFileContents: Data?
    
    init(
        packageRoot: URL,
        toolsVersion: SwiftVersion,
        swiftVersion: SwiftVersion,
        staticLinuxSDK: StaticLinuxSDK,
        isSwiftlyAvailable: Bool,
        isToolchainAvailable: Bool,
        isStaticLinuxSDKAvailable: Bool,
        requiredComponents: [PreparationComponent],
        target: BuildTarget,
        swiftVersionPreference: String?,
        swiftVersionFileURL: URL?,
        swiftlyExecutableURL: URL?,
        sdkDownloadURL: URL,
        sdkChecksum: String,
        sdkBundleURL: URL?,
        manifestContents: Data,
        swiftVersionFileContents: Data?
    ) {
        self.packageRoot = packageRoot
        self.toolsVersion = toolsVersion
        self.swiftVersion = swiftVersion
        self.staticLinuxSDK = staticLinuxSDK
        self.isSwiftlyAvailable = isSwiftlyAvailable
        self.isToolchainAvailable = isToolchainAvailable
        self.isStaticLinuxSDKAvailable = isStaticLinuxSDKAvailable
        self.requiredComponents = requiredComponents
        self.target = target
        self.swiftVersionPreference = swiftVersionPreference
        self.swiftVersionFileURL = swiftVersionFileURL
        self.swiftlyExecutableURL = swiftlyExecutableURL
        self.sdkDownloadURL = sdkDownloadURL
        self.sdkChecksum = sdkChecksum
        self.sdkBundleURL = sdkBundleURL
        self.manifestContents = manifestContents
        self.swiftVersionFileContents = swiftVersionFileContents
    }
    
}

extension EnvironmentAssessment {
    
    /// Whether authorization would install at least one component.
    public var requiresPreparation: Bool {
        !requiredComponents.isEmpty
    }
    
}
