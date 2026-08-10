import Foundation

/// One official stable Swift toolchain and its matching Static Linux SDK.
struct OfficialStableRelease: Hashable, Sendable {

    let version: SwiftVersion
    let staticLinuxSDK: StaticLinuxSDK
    let staticLinuxSDKMetadata: StaticLinuxSDKMetadata

    func supports(_ architecture: LinuxArchitecture) -> Bool {
        staticLinuxSDKMetadata.supportedArchitectures.contains(architecture)
    }

}

/// Internal release metadata for an official Static Linux SDK.
struct StaticLinuxSDKMetadata: Hashable, Sendable {

    let downloadURL: URL
    let checksum: String
    let supportedArchitectures: Set<LinuxArchitecture>

}
