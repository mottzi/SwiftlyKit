import Foundation

/// A read-only result for one exact build environment and its unavailable components.
public struct EnvironmentAssessment: Sendable {

    /// The unavailable components that preparation is authorized to install.
    public let requiredComponents: [PreparationComponent]

    let packageInputs: PackageInputSnapshot
    let release: OfficialStableRelease
    let target: BuildTarget
    let environmentStorage: EnvironmentStorage

    init(
        packageInputs: PackageInputSnapshot,
        release: OfficialStableRelease,
        requiredComponents: [PreparationComponent],
        target: BuildTarget,
        environmentStorage: EnvironmentStorage = .standard
    ) {

        self.packageInputs = packageInputs
        self.release = release
        self.requiredComponents = requiredComponents
        self.target = target
        self.environmentStorage = environmentStorage
    }

}

extension EnvironmentAssessment {
    
    /// The canonical package root that the assessment captured.
    public var packageRoot: URL {
        packageInputs.packageRoot
    }

    /// The Swift tools version that the package manifest declared during assessment.
    public var toolsVersion: SwiftVersion {
        packageInputs.toolsVersion
    }

    /// The exact official Swift release that the assessment selected.
    public var swiftVersion: SwiftVersion {
        release.version
    }

    /// The exact Static Linux SDK that is paired with the selected Swift release.
    public var staticLinuxSDK: StaticLinuxSDK {
        release.staticLinuxSDK
    }

    /// `true` if the assessment did not require Swiftly installation.
    public var isSwiftlyAvailable: Bool {
        !requiredComponents.contains(.swiftly)
    }

    /// `true` if the assessment did not require installation of the selected toolchain.
    public var isToolchainAvailable: Bool {
        !requiredComponents.contains(.toolchain)
    }

    /// `true` if the assessment did not require installation of the selected Static Linux SDK.
    public var isStaticLinuxSDKAvailable: Bool {
        !requiredComponents.contains(.staticLinuxSDK)
    }

    /// `true` if the assessment authorizes installation of one or more components.
    public var requiresInstallation: Bool {
        !requiredComponents.isEmpty
    }
    
}
