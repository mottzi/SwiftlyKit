import Foundation

/// Fetches the official stable Swift release catalog without retaining network state.
struct SwiftOrgReleaseCatalog: Sendable {

    private(set) var load: @Sendable (URL) async throws -> Response = { url in
        try await SwiftOrgReleaseCatalog.liveLoad(url)
    }

    func stableReleases() async throws -> [OfficialStableRelease] {

        try Task.checkCancellation()

        do {
            let response = try await load(Self.releasesURL)
            try Task.checkCancellation()

            guard response.statusCode == 200
            else { throw CatalogError.networkFailure }

            return try Self.parse(response.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CatalogError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw CatalogError.networkFailure
        }
    }

}

extension SwiftOrgReleaseCatalog {

    struct Response: Sendable {
        let data: Data
        let statusCode: Int?
    }

    enum CatalogError: Error, Equatable, Sendable {
        case networkFailure
        case invalidPayload
    }

}

extension SwiftOrgReleaseCatalog {

    /// Narrows Swift.org's evolving public schema to exact stable toolchain and SDK pairs.
    private static func parse(_ data: Data) throws -> [OfficialStableRelease] {

        let payloads: [ReleasePayload]
        do { payloads = try JSONDecoder().decode([ReleasePayload].self, from: data) }
        catch { throw CatalogError.invalidPayload }

        return payloads.compactMap(release(from:))
    }

    private static func release(from payload: ReleasePayload) -> OfficialStableRelease? {

        guard let name = payload.name else { return nil }
        guard let version = SwiftVersion(parsing: name) else { return nil }
        guard payload.tag == "swift-\(name)-RELEASE" else { return nil }
        
        guard let platform = payload.platforms?.first(where: { $0.platform == "static-sdk" }) else { return nil }
        guard let sdkVersion = platform.version else { return nil }
        guard SwiftVersion(parsing: sdkVersion) != nil else { return nil }
        guard let checksum = platform.checksum else { return nil }

        let architectures = Set((platform.archs ?? []).compactMap(LinuxArchitecture.init(catalogName:)))

        let identifier = "swift-\(name)-RELEASE_static-linux-\(sdkVersion)"
        let releaseDirectory = "swift-\(name.lowercased())-release"
        let filename = "\(identifier).artifactbundle.tar.gz"
        let downloadDirectoryURL = "https://download.swift.org/\(releaseDirectory)/static-sdk"
        let downloadURLString = "\(downloadDirectoryURL)/swift-\(name)-RELEASE/\(filename)"

        guard let downloadURL = URL(string: downloadURLString) else { return nil }

        let sdk = StaticLinuxSDK(identifier: identifier, version: sdkVersion)
        guard let metadata = StaticLinuxSDKMetadata(
            downloadURL: downloadURL,
            checksum: checksum,
            supportedArchitectures: architectures
        ) else { return nil }

        return OfficialStableRelease(
            version: version,
            staticLinuxSDK: sdk,
            staticLinuxSDKMetadata: metadata
        )
    }

}

extension LinuxArchitecture {

    fileprivate init?(catalogName: String) {

        switch catalogName {
            case "arm64": self = .arm64
            case "x86_64": self = .x86_64
            default: return nil
        }
    }

}

extension SwiftOrgReleaseCatalog {

    private static func liveLoad(_ url: URL) async throws -> Response {

        let (data, response) = try await URLSession.shared.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode

        return Response(data: data, statusCode: statusCode)
    }

}

extension SwiftOrgReleaseCatalog {

    private struct ReleasePayload: Decodable {

        let name: String?
        let tag: String?
        let platforms: [PlatformPayload]?

    }

    private struct PlatformPayload: Decodable {

        let platform: String?
        let version: String?
        let checksum: String?
        let archs: [String]?

    }

}

extension SwiftOrgReleaseCatalog {

    private static let releasesURL = URL(string: "https://www.swift.org/api/v1/install/releases.json")!

}
