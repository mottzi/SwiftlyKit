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

    init?(
        downloadURL: URL,
        checksum: String,
        supportedArchitectures: Set<LinuxArchitecture>
    ) {

        guard downloadURL.scheme?.lowercased() == "https" else { return nil }
        guard checksum.utf8.count == 64 else { return nil }
        guard checksum.isASCIIHexadecimal else { return nil }
        guard !supportedArchitectures.isEmpty else { return nil }

        self.downloadURL = downloadURL
        self.checksum = checksum.lowercased()
        self.supportedArchitectures = supportedArchitectures
    }

}
