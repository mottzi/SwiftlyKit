/// Pure, deterministic selection of one exact official toolchain and matching SDK.
enum EnvironmentSelectionPolicy {

    static func select(
        toolchain: ToolchainSelection,
        toolsVersion: SwiftVersion,
        swiftVersionPreference: String?,
        architecture: LinuxArchitecture,
        releases: [OfficialStableRelease],
        installedToolchains: [SwiftVersion],
        installedSDKs: [InstalledStaticLinuxSDK]
    ) throws -> OfficialStableRelease {

        let releases = canonicalReleases(releases)
        
        if case .exact(let version) = toolchain {
            return try selectExact(version, toolsVersion: toolsVersion, architecture: architecture, releases: releases)
        }

        if let swiftVersionPreference {
            guard let version = SwiftVersion(parsing: swiftVersionPreference)
            else { throw SelectionError.invalidSwiftVersionPreference(swiftVersionPreference) }
            return try selectExact(version, toolsVersion: toolsVersion, architecture: architecture, releases: releases)
        }

        let installedVersions = Set(installedToolchains)
        let installedSDKs = Set(installedSDKs)

        let installedRelease = releases.first { release in
            guard release.version >= toolsVersion else { return false }
            guard release.supports(architecture) else { return false }
            guard installedVersions.contains(release.version) else { return false }

            let installedSDK = InstalledStaticLinuxSDK(
                toolchainVersion: release.version,
                identifier: release.staticLinuxSDK.identifier
            )

            return installedSDKs.contains(installedSDK)
        }
        
        if let installedRelease { return installedRelease }

        let compatibleRelease = releases.first { release in
            guard release.version >= toolsVersion else { return false }
            guard release.supports(architecture) else { return false }
            return true
        }

        if let compatibleRelease { return compatibleRelease }
        
        throw SelectionError.noCompatibleRelease(toolsVersion: toolsVersion, architecture: architecture)
    }

}

extension EnvironmentSelectionPolicy {

    enum SelectionError: Error, Equatable, Sendable {
        case invalidSwiftVersionPreference(String)
        case unavailableRelease(SwiftVersion)
        case incompatibleToolsVersion(requested: SwiftVersion, required: SwiftVersion)
        case unsupportedArchitecture(version: SwiftVersion, architecture: LinuxArchitecture)
        case noCompatibleRelease(toolsVersion: SwiftVersion, architecture: LinuxArchitecture)
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
    ) throws -> OfficialStableRelease {

        guard let release = releases.first(where: { $0.version == version })
        else { throw SelectionError.unavailableRelease(version) }
        
        guard version >= toolsVersion
        else { throw SelectionError.incompatibleToolsVersion(requested: version, required: toolsVersion) }
        
        guard release.supports(architecture)
        else { throw SelectionError.unsupportedArchitecture(version: version, architecture: architecture) }

        return release
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
