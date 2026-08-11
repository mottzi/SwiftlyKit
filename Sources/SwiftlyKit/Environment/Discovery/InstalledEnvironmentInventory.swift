/// Canonical installed toolchain and SDK state observed through Swiftly.
struct InstalledEnvironmentInventory: Equatable {

    let toolchains: [SwiftVersion]
    let sdks: [InstalledStaticLinuxSDK]

    func contains(toolchain version: SwiftVersion) -> Bool {
        toolchains.contains(version)
    }

    func contains(toolchain version: SwiftVersion, sdk identifier: String) -> Bool {
        contains(toolchain: version) && sdks.contains {
            $0.toolchainVersion == version && $0.identifier == identifier
        }
    }

}

/// A Static Linux SDK visible through one exact installed Swift toolchain.
struct InstalledStaticLinuxSDK: Hashable {

    let toolchainVersion: SwiftVersion
    let identifier: String

}
