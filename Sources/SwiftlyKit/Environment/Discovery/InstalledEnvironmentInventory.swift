/// Canonical installed toolchain and SDK state observed through Swiftly.
struct InstalledEnvironmentInventory: Equatable, Sendable {

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
struct InstalledStaticLinuxSDK: Hashable, Sendable {

    let toolchainVersion: SwiftVersion
    let identifier: String

}

/// Any SDK identifier registered in Swift's shared SDK registry.
struct RegisteredSDK: Hashable, Sendable {

    let identifier: String

}

/// The result of probing Swift's shared SDK registry through one manager.
enum SDKInspection: Hashable, Sendable {

    /// The selected SDK registry was read successfully through this registered toolchain.
    case available(manager: SwiftVersion)

    /// No registered stable toolchain could read the selected SDK registry.
    case unavailable

    /// A custom SDK registry does not exist yet and is therefore empty.
    case absent

    /// A manager returned success, but its SDK listing was malformed.
    case malformed

    /// SDK inspection was intentionally skipped, as for toolchain-only removal.
    case notRequested

}

/// Raw stable toolchain state needed to make a safe removal decision.
struct RegisteredToolchain: Hashable, Sendable {

    let version: SwiftVersion
    let isInUse: Bool
    let isDefault: Bool
    let selectionStateIsKnown: Bool

    init(
        version: SwiftVersion,
        isInUse: Bool,
        isDefault: Bool,
        selectionStateIsKnown: Bool = true
    ) {
        self.version = version
        self.isInUse = isInUse
        self.isDefault = isDefault
        self.selectionStateIsKnown = selectionStateIsKnown
    }

}

/// Raw Swiftly state used only by environment removal.
struct EnvironmentRemovalInventory: Hashable, Sendable {

    let toolchains: [RegisteredToolchain]
    let sdks: [RegisteredSDK]
    let sdkInspection: SDKInspection

    func toolchain(_ version: SwiftVersion) -> RegisteredToolchain? {
        toolchains.first { $0.version == version }
    }

    func contains(sdk identifier: String) -> Bool {
        sdks.contains { $0.identifier == identifier }
    }

    var sdkManager: SwiftVersion? {
        guard case .available(let manager) = sdkInspection else { return nil }
        return manager
    }

}
