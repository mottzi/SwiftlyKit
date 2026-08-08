import Foundation

/// A read-only description of the exact environment SwiftlyKit will prepare.
public struct EnvironmentAssessment: Sendable {
    
    public let requiredComponents: [PreparationComponent]

    /// The canonical package root captured during assessment.
    public var packageRoot: URL {
        packageInputs.requirements.packageRoot
    }

    /// The package's declared Swift tools version.
    public var toolsVersion: SwiftVersion {
        packageInputs.requirements.toolsVersion
    }

    /// The exact official Swift release selected for the package.
    public var swiftVersion: SwiftVersion {
        release.version
    }

    /// The matching exact Static Linux SDK.
    public var staticLinuxSDK: StaticLinuxSDK {
        StaticLinuxSDK(
            identifier: release.staticLinuxSDK.identifier,
            version: release.staticLinuxSDK.version
        )
    }

    /// Whether a compatible Swiftly installation is already available.
    public var isSwiftlyAvailable: Bool {
        !requiredComponents.contains(.swiftly)
    }

    /// Whether the selected toolchain is already available.
    public var isToolchainAvailable: Bool {
        !requiredComponents.contains(.toolchain)
    }

    /// Whether the selected Static Linux SDK is already available.
    public var isStaticLinuxSDKAvailable: Bool {
        !requiredComponents.contains(.staticLinuxSDK)
    }

    /// Whether preparation will install at least one component.
    public var requiresInstallation: Bool {
        !requiredComponents.isEmpty
    }
    
    let packageInputs: PackageInputSnapshot
    let release: OfficialStableRelease
    let target: BuildTarget
    
    init(
        packageInputs: PackageInputSnapshot,
        release: OfficialStableRelease,
        requiredComponents: [PreparationComponent],
        target: BuildTarget
    ) {
        self.packageInputs = packageInputs
        self.release = release
        self.requiredComponents = requiredComponents
        self.target = target
    }
    
}
