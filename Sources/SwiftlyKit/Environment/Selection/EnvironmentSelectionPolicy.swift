/// Pure, deterministic selection of one exact official toolchain and matching SDK.
enum EnvironmentSelectionPolicy {

    static func select(
        toolchain: ToolchainSelection,
        toolsVersion: SwiftVersion,
        swiftVersionPreference: String?,
        architecture: LinuxArchitecture,
        releases: [OfficialStableRelease],
        inventory: InstalledEnvironmentInventory
    ) throws(SelectionError) -> OfficialStableRelease {

        let releases = canonicalReleases(releases)
        
        if case .exact(let version) = toolchain {
            return try selectExact(version, toolsVersion: toolsVersion, architecture: architecture, releases: releases)
        }

        if let swiftVersionPreference {
            guard let version = SwiftVersion(parsing: swiftVersionPreference)
            else { throw SelectionError.invalidSwiftVersionPreference(swiftVersionPreference) }
            return try selectExact(version, toolsVersion: toolsVersion, architecture: architecture, releases: releases)
        }

        let compatibleReleases = compatibleReleases(
            toolsVersion: toolsVersion,
            architecture: architecture,
            canonicalReleases: releases
        )

        let installedRelease = compatibleReleases.first { release in
            inventory.contains(toolchain: release.version, sdk: release.staticLinuxSDK.identifier)
        }
        
        if let installedRelease { return installedRelease }

        let compatibleRelease = compatibleReleases.first

        if let compatibleRelease { return compatibleRelease }
        
        throw SelectionError.noCompatibleRelease(toolsVersion: toolsVersion, architecture: architecture)
    }

    /// Returns unique compatible official releases in newest-first order.
    static func compatibleReleases(
        toolsVersion: SwiftVersion,
        architecture: LinuxArchitecture,
        releases: [OfficialStableRelease]
    ) -> [OfficialStableRelease] {

        compatibleReleases(
            toolsVersion: toolsVersion,
            architecture: architecture,
            canonicalReleases: canonicalReleases(releases)
        )
    }

}

extension EnvironmentSelectionPolicy {

    private static func canonicalReleases(_ releases: [OfficialStableRelease]) -> [OfficialStableRelease] {

        var releasesByVersion: [SwiftVersion: OfficialStableRelease] = [:]
        
        for release in releases {
            releasesByVersion[release.version] = release
        }

        return releasesByVersion.values.sorted { $0.version > $1.version }
    }

    private static func selectExact(
        _ version: SwiftVersion,
        toolsVersion: SwiftVersion,
        architecture: LinuxArchitecture,
        releases: [OfficialStableRelease]
    ) throws(SelectionError) -> OfficialStableRelease {

        guard let release = releases.first(where: { $0.version == version })
        else { throw SelectionError.unavailableRelease(version) }
        
        guard version >= toolsVersion
        else { throw SelectionError.incompatibleToolsVersion(requested: version, required: toolsVersion) }
        
        guard release.supports(architecture)
        else { throw SelectionError.unsupportedArchitecture(version: version, architecture: architecture) }

        return release
    }

    private static func compatibleReleases(
        toolsVersion: SwiftVersion,
        architecture: LinuxArchitecture,
        canonicalReleases: [OfficialStableRelease]
    ) -> [OfficialStableRelease] {

        canonicalReleases.filter { release in
            release.version >= toolsVersion && release.supports(architecture)
        }
    }

}

extension EnvironmentSelectionPolicy {

    enum SelectionError: Error, Equatable {
        case invalidSwiftVersionPreference(String)
        case unavailableRelease(SwiftVersion)
        case incompatibleToolsVersion(requested: SwiftVersion, required: SwiftVersion)
        case unsupportedArchitecture(version: SwiftVersion, architecture: LinuxArchitecture)
        case noCompatibleRelease(toolsVersion: SwiftVersion, architecture: LinuxArchitecture)
    }

}

extension EnvironmentSelectionPolicy.SelectionError {

    var swiftlyKitError: SwiftlyKitError {
        switch self {
            case .incompatibleToolsVersion(_, let required): .unsupportedToolsVersion(required)
            case .invalidSwiftVersionPreference, .unavailableRelease, .noCompatibleRelease: .compatibleReleaseUnavailable
            case .unsupportedArchitecture: .staticLinuxSDKUnavailable
        }
    }

}
