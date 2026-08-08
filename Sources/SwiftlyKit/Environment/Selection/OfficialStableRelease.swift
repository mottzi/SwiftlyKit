import Foundation

/// One official stable Swift toolchain and its matching Static Linux SDK.
struct OfficialStableRelease: Hashable, Sendable {

    let version: SwiftVersion
    let staticLinuxSDK: OfficialStaticLinuxSDK

}

/// Installation metadata for an official Static Linux SDK.
struct OfficialStaticLinuxSDK: Hashable, Sendable {

    let version: String
    let identifier: String
    let downloadURL: URL
    let checksum: String
    let supportedArchitectures: Set<LinuxArchitecture>

    func supports(_ architecture: LinuxArchitecture) -> Bool {
        supportedArchitectures.contains(architecture)
    }

}
