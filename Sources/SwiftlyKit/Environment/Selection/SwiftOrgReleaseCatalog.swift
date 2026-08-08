import Foundation

/// Fetches the official stable Swift release catalog without retaining network state.
struct SwiftOrgReleaseCatalog: Sendable {
    init() {
        self.init { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            return Response(data: data, statusCode: statusCode)
        }
    }

    init(load: @escaping @Sendable (URL) async throws -> Response) {
        self.load = load
    }

    func stableReleases() async throws -> [OfficialStableRelease] {
        try Task.checkCancellation()

        do {
            let response = try await load(Self.releasesURL)
            try Task.checkCancellation()
            guard response.statusCode == 200 else {
                throw CatalogError.unexpectedResponse(statusCode: response.statusCode)
            }
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

    /// Narrows Swift.org's evolving public schema to exact stable toolchain and SDK pairs.
    static func parse(_ data: Data) throws -> [OfficialStableRelease] {
        let payloads: [ReleasePayload]
        do {
            payloads = try JSONDecoder().decode([ReleasePayload].self, from: data)
        } catch {
            throw CatalogError.invalidPayload
        }

        var releasesByVersion: [SwiftVersion: OfficialStableRelease] = [:]
        for payload in payloads {
            guard let release = release(from: payload) else { continue }
            releasesByVersion[release.version] = release
        }

        return releasesByVersion.values.sorted { $0.version > $1.version }
    }

    private let load: @Sendable (URL) async throws -> Response
}

extension SwiftOrgReleaseCatalog {
    struct Response: Sendable {
        let data: Data
        let statusCode: Int?
    }

    enum CatalogError: Error, Equatable, Sendable {
        case networkFailure
        case unexpectedResponse(statusCode: Int?)
        case invalidPayload
    }
}

extension SwiftOrgReleaseCatalog {
    private static func release(from payload: ReleasePayload) -> OfficialStableRelease? {
        guard let name = payload.name,
              let version = SwiftVersion(parsing: name),
              payload.tag == "swift-\(name)-RELEASE",
              let platform = payload.platforms?.first(where: { $0.platform == "static-sdk" }),
              let sdkVersion = platform.version,
              SwiftVersion(parsing: sdkVersion) != nil,
              let checksum = normalizedChecksum(platform.checksum)
        else { return nil }

        let architectures = Set((platform.archs ?? []).compactMap(LinuxArchitecture.init(catalogName:)))
        guard !architectures.isEmpty else { return nil }

        let identifier = "swift-\(name)-RELEASE_static-linux-\(sdkVersion)"
        let releaseDirectory = "swift-\(name.lowercased())-release"
        let filename = "\(identifier).artifactbundle.tar.gz"
        guard let downloadURL = URL(
            string: "https://download.swift.org/\(releaseDirectory)/static-sdk/swift-\(name)-RELEASE/\(filename)"
        ) else { return nil }

        let sdk = OfficialStaticLinuxSDK(
            version: sdkVersion,
            identifier: identifier,
            downloadURL: downloadURL,
            checksum: checksum,
            supportedArchitectures: architectures
        )
        return OfficialStableRelease(version: version, staticLinuxSDK: sdk)
    }

    private static func normalizedChecksum(_ checksum: String?) -> String? {
        guard let checksum, checksum.utf8.count == 64 else { return nil }
        guard checksum.utf8.allSatisfy({ byte in
            byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!
                || byte >= Character("a").asciiValue! && byte <= Character("f").asciiValue!
                || byte >= Character("A").asciiValue! && byte <= Character("F").asciiValue!
        }) else { return nil }
        return checksum.lowercased()
    }

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
    static let releasesURL = URL(string: "https://www.swift.org/api/v1/install/releases.json")!
}
