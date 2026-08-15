import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Swift.org release catalog")
struct SwiftOrgReleaseCatalogTests {

    @Test("Official static SDK metadata produces exact identities and URLs")
    func parsesOfficialMetadata() async throws {

        let data = Data("""
            [
              {
                "name": "6.3",
                "tag": "swift-6.3-RELEASE",
                "platforms": [{
                  "platform": "static-sdk",
                  "version": "0.1.0",
                  "checksum": "D2078B69BDEB5C31202C10E9D8A11D6F66F82938B51A4B75F032CCB35C4C286C",
                  "archs": ["x86_64", "arm64"]
                }]
              },
              {
                "name": "6.3.3",
                "tag": "swift-6.3.3-RELEASE",
                "platforms": [{
                  "platform": "static-sdk",
                  "version": "0.1.0",
                  "checksum": "87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b",
                  "archs": ["x86_64", "arm64"]
                }]
              }
            ]
            """.utf8)

        let catalog = SwiftOrgReleaseCatalog { _ in
            .init(data: data, statusCode: 200)
        }
        let releases = try await catalog.stableReleases()

        #expect(releases.map(\.version) == [swiftVersion("6.3"), swiftVersion("6.3.3")])
        #expect(releases[0].staticLinuxSDK.identifier == "swift-6.3-RELEASE_static-linux-0.1.0")
        #expect(releases[0].staticLinuxSDK.version == "0.1.0")
        #expect(releases[0].staticLinuxSDKMetadata.downloadURL.absoluteString ==
            "https://download.swift.org/swift-6.3-release/static-sdk/swift-6.3-RELEASE/swift-6.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz")
        #expect(releases[0].staticLinuxSDKMetadata.checksum ==
            "d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c")
        #expect(releases[0].staticLinuxSDKMetadata.supportedArchitectures == [.arm64, .x86_64])
    }

    @Test("Malformed and non-SDK releases are excluded without poisoning valid releases")
    func filtersUnusableEntries() async throws {

        let checksum = String(repeating: "a", count: 64)
        let data = Data("""
            [
              {"name":"snapshot", "tag":"swift-snapshot", "platforms":[]},
              {"name":"6.2.4", "tag":"wrong-tag", "platforms":[{"platform":"static-sdk","version":"0.1.0","checksum":"\(checksum)","archs":["arm64"]}]},
              {"name":"6.2.3", "tag":"swift-6.2.3-RELEASE", "platforms":[]},
              {"name":"6.2.2", "tag":"swift-6.2.2-RELEASE", "platforms":[{"platform":"static-sdk","version":"0.0.1","checksum":"bad","archs":["arm64"]}]},
              {"name":"6.2.1", "tag":"swift-6.2.1-RELEASE", "platforms":[{"platform":"static-sdk","version":"0.0.1","checksum":"\(checksum)","archs":["future"]}]},
              {"name":"6.2", "tag":"swift-6.2-RELEASE", "platforms":[{"platform":"static-sdk","version":"0.0.1","checksum":"\(checksum)","archs":["arm64"]}]}
            ]
            """.utf8)

        let catalog = SwiftOrgReleaseCatalog { _ in
            .init(data: data, statusCode: 200)
        }
        let releases = try await catalog.stableReleases()
        #expect(releases.map(\.version) == [swiftVersion("6.2")])
    }

    @Test("Invalid JSON is a catalog payload error")
    func rejectsInvalidJSON() async {

        let catalog = SwiftOrgReleaseCatalog { _ in
            .init(data: Data("not json".utf8), statusCode: 200)
        }

        await #expect(throws: SwiftOrgReleaseCatalog.CatalogError.invalidPayload) {
            try await catalog.stableReleases()
        }
    }

    @Test("Fetching classifies an unsuccessful HTTP response as a network failure")
    func validatesHTTPResponse() async {

        let catalog = SwiftOrgReleaseCatalog { url in
            #expect(url.absoluteString == "https://www.swift.org/api/v1/install/releases.json")
            return .init(data: Data("[]".utf8), statusCode: 503)
        }

        await #expect(throws: SwiftOrgReleaseCatalog.CatalogError.networkFailure) {
            try await catalog.stableReleases()
        }
    }

    @Test("A recent observation is reused until its refresh interval expires")
    func reusesRecentObservation() async throws {

        let counter = CatalogLoadCounter(data: catalogData())
        let catalog = SwiftOrgReleaseCatalog(
            load: { _ in await counter.response() },
            cache: SwiftOrgReleaseCache(fileURL: nil),
            now: Date.init
        )

        _ = try await catalog.stableReleases()
        _ = try await catalog.stableReleases()

        #expect(await counter.count == 1)
    }

    @Test("An expired observation causes a new live request")
    func refreshesExpiredObservation() async throws {

        let counter = CatalogLoadCounter(data: catalogData())
        let catalog = SwiftOrgReleaseCatalog(
            load: { _ in await counter.response() },
            cache: SwiftOrgReleaseCache(fileURL: nil),
            now: Date.init,
            refreshInterval: 0
        )

        _ = try await catalog.stableReleases()
        _ = try await catalog.stableReleases()

        #expect(await counter.count == 2)
    }

    @Test("Concurrent callers share one live request")
    func coalescesConcurrentRequests() async throws {

        let probe = CatalogLoadProbe(data: catalogData())
        let catalog = SwiftOrgReleaseCatalog(load: { _ in await probe.response() })
        let first = Task { try await catalog.stableReleases() }

        await probe.waitUntilStarted()

        let second = Task { try await catalog.stableReleases() }
        await Task.yield()

        #expect(await probe.count == 1)

        await probe.complete()

        let firstReleases = try await first.value
        let secondReleases = try await second.value

        #expect(firstReleases == secondReleases)
        #expect(await probe.count == 1)
    }

    @Test("Cancellation releases a caller and cancels an unobserved refresh")
    func cancelsUnobservedRefresh() async throws {

        let probe = CatalogLoadProbe(data: catalogData())
        let catalog = SwiftOrgReleaseCatalog(load: { _ in await probe.response() })
        let request = Task { try await catalog.stableReleases() }

        await probe.waitUntilStarted()
        request.cancel()

        await #expect(throws: CancellationError.self) {
            try await request.value
        }

        await probe.complete()
    }

    @Test("A validated response replaces one private persistent snapshot")
    func persistsValidatedResponse() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Catalog") { directory in
            let file = directory.appending(path: "cache/releases.json")
            let cache = SwiftOrgReleaseCache(fileURL: file)
            let catalog = SwiftOrgReleaseCatalog(
                load: { _ in .init(data: catalogData(), statusCode: 200) },
                cache: cache,
                now: Date.init
            )

            let live = try await catalog.stableReleases()
            let replacement = SwiftOrgReleaseCatalog(
                load: { _ in throw SwiftOrgReleaseCatalog.CatalogError.networkFailure },
                cache: cache,
                now: Date.init
            )
            let cached = await replacement.cachedReleases()
            let attributes = try FileManager.default.attributesOfItem(
                atPath: file.path(percentEncoded: false)
            )
            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: file.deletingLastPathComponent().path(percentEncoded: false)
            )
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            let directoryPermissions = try #require(directoryAttributes[.posixPermissions] as? NSNumber)

            #expect(cached == live)
            #expect(permissions.intValue & 0o777 == 0o600)
            #expect(directoryPermissions.intValue & 0o777 == 0o700)
        }
    }

    @Test("Cache write failure does not reject a valid live response")
    func toleratesCacheWriteFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Catalog") { directory in
            let file = directory.appending(path: "missing/cache/releases.json")
            let catalog = SwiftOrgReleaseCatalog(
                load: { _ in .init(data: catalogData(), statusCode: 200) },
                cache: SwiftOrgReleaseCache(fileURL: file),
                now: Date.init
            )

            let releases = try await catalog.stableReleases()

            #expect(releases.map(\.version) == [swiftVersion("6.3.3")])
            #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        }
    }

    @Test("A malformed persistent snapshot is unavailable")
    func rejectsMalformedCache() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Catalog") { directory in
            let cacheDirectory = directory.appending(path: "cache", directoryHint: .isDirectory)
            let file = cacheDirectory.appending(path: "releases.json")

            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: false)
            try Data("not json".utf8).write(to: file)

            let catalog = SwiftOrgReleaseCatalog(
                load: { _ in throw SwiftOrgReleaseCatalog.CatalogError.networkFailure },
                cache: SwiftOrgReleaseCache(fileURL: file),
                now: Date.init
            )

            #expect(await catalog.cachedReleases() == nil)
        }
    }

    @Test("A symbolic-link cache path is unavailable")
    func rejectsSymbolicLinkCachePath() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Catalog") { directory in
            let storage = directory.appending(path: "storage", directoryHint: .isDirectory)
            let link = directory.appending(path: "cache", directoryHint: .isDirectory)
            let storedFile = storage.appending(path: "releases.json")
            let linkedFile = link.appending(path: "releases.json")

            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
            try catalogData().write(to: storedFile)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: storage)

            let catalog = SwiftOrgReleaseCatalog(
                load: { _ in throw SwiftOrgReleaseCatalog.CatalogError.networkFailure },
                cache: SwiftOrgReleaseCache(fileURL: linkedFile),
                now: Date.init
            )

            #expect(await catalog.cachedReleases() == nil)
        }
    }

}

private actor CatalogLoadCounter {

    private let data: Data
    private(set) var count = 0

    init(data: Data) {
        self.data = data
    }

    func response() -> SwiftOrgReleaseCatalog.Response {
        count += 1
        return SwiftOrgReleaseCatalog.Response(data: data, statusCode: 200)
    }

}

private actor CatalogLoadProbe {

    private let data: Data
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<SwiftOrgReleaseCatalog.Response, Never>] = []
    private var completed = false
    private(set) var count = 0

    init(data: Data) {
        self.data = data
    }

    func response() async -> SwiftOrgReleaseCatalog.Response {

        count += 1

        let startWaiters = startWaiters
        self.startWaiters.removeAll()
        startWaiters.forEach { $0.resume() }

        if completed { return makeResponse() }

        return await withCheckedContinuation { continuation in
            responseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {

        if count > 0 { return }

        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func complete() {

        completed = true

        let response = makeResponse()
        let responseWaiters = responseWaiters
        self.responseWaiters.removeAll()
        responseWaiters.forEach { $0.resume(returning: response) }
    }

    private func makeResponse() -> SwiftOrgReleaseCatalog.Response {
        SwiftOrgReleaseCatalog.Response(data: data, statusCode: 200)
    }

}

private func catalogData(_ version: String = "6.3.3") -> Data {

    let checksum = String(repeating: "a", count: 64)
    return Data("""
        [{
          "name": "\(version)",
          "tag": "swift-\(version)-RELEASE",
          "platforms": [{
            "platform": "static-sdk",
            "version": "0.1.0",
            "checksum": "\(checksum)",
            "archs": ["x86_64", "arm64"]
          }]
        }]
        """.utf8)
}

private func swiftVersion(_ value: String) -> SwiftVersion {
    SwiftVersion(value)!
}
