/// Pure, deterministic selection of one exact official toolchain and matching SDK.
enum EnvironmentSelectionPolicy {
    static func select(
        toolchain: ToolchainSelection,
        toolsVersion: SwiftVersion,
        swiftVersionPreference: String?,
        architecture: LinuxArchitecture,
        releases: [OfficialStableRelease],
        installedToolchains: [InstalledStableToolchain],
        installedSDKs: [InstalledStaticLinuxSDK]
    ) throws -> SelectedEnvironmentRelease {
        let releases = canonicalReleases(releases)

        switch toolchain {
            case .exact(let version):
                return try selectExact(
                    version,
                    source: .exactRequest,
                    toolsVersion: toolsVersion,
                    architecture: architecture,
                    releases: releases
                )
            case .automatic:
                break
        }

        if let preference = swiftVersionPreference {
            guard let version = SwiftVersion(parsing: preference) else {
                throw SelectionError.invalidSwiftVersionPreference(preference)
            }
            return try selectExact(
                version,
                source: .swiftVersionPreference,
                toolsVersion: toolsVersion,
                architecture: architecture,
                releases: releases
            )
        }

        let installedVersions = Set(installedToolchains.map(\.version))
        let installedPairs = Set(installedSDKs.map {
            InstalledPair(toolchainVersion: $0.toolchainVersion, sdkIdentifier: $0.identifier)
        })
        if let release = releases.first(where: { release in
            release.version >= toolsVersion
                && release.staticLinuxSDK.supports(architecture)
                && installedVersions.contains(release.version)
                && installedPairs.contains(InstalledPair(
                    toolchainVersion: release.version,
                    sdkIdentifier: release.staticLinuxSDK.identifier
                ))
        }) {
            return SelectedEnvironmentRelease(release: release, source: .installedPair)
        }

        guard let release = releases.first(where: {
            $0.version >= toolsVersion && $0.staticLinuxSDK.supports(architecture)
        }) else {
            throw SelectionError.noCompatibleRelease(
                toolsVersion: toolsVersion,
                architecture: architecture
            )
        }
        return SelectedEnvironmentRelease(release: release, source: .newestOfficial)
    }
}

struct SelectedEnvironmentRelease: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case exactRequest
        case swiftVersionPreference
        case installedPair
        case newestOfficial
    }

    let release: OfficialStableRelease
    let source: Source
}

extension EnvironmentSelectionPolicy {
    enum SelectionError: Error, Equatable, Sendable {
        case invalidSwiftVersionPreference(String)
        case unavailableRelease(SwiftVersion)
        case incompatibleToolsVersion(requested: SwiftVersion, required: SwiftVersion)
        case unsupportedArchitecture(version: SwiftVersion, architecture: LinuxArchitecture)
        case noCompatibleRelease(toolsVersion: SwiftVersion, architecture: LinuxArchitecture)
    }

    private struct InstalledPair: Hashable {
        let toolchainVersion: SwiftVersion
        let sdkIdentifier: String
    }

    private static func selectExact(
        _ version: SwiftVersion,
        source: SelectedEnvironmentRelease.Source,
        toolsVersion: SwiftVersion,
        architecture: LinuxArchitecture,
        releases: [OfficialStableRelease]
    ) throws -> SelectedEnvironmentRelease {
        guard let release = releases.first(where: { $0.version == version }) else {
            throw SelectionError.unavailableRelease(version)
        }
        guard version >= toolsVersion else {
            throw SelectionError.incompatibleToolsVersion(requested: version, required: toolsVersion)
        }
        guard release.staticLinuxSDK.supports(architecture) else {
            throw SelectionError.unsupportedArchitecture(version: version, architecture: architecture)
        }
        return SelectedEnvironmentRelease(release: release, source: source)
    }

    private static func canonicalReleases(
        _ releases: [OfficialStableRelease]
    ) -> [OfficialStableRelease] {
        var releasesByVersion: [SwiftVersion: OfficialStableRelease] = [:]
        for release in releases {
            releasesByVersion[release.version] = release
        }
        return releasesByVersion.values.sorted { $0.version > $1.version }
    }
}
