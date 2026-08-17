import Foundation

/// Process-wide coordinator for validated official stable Swift release-catalog observations.
actor SwiftOrgReleaseCatalog {

    typealias Loader = @Sendable (URL) async throws -> Response
    typealias DateProvider = @Sendable () -> Date

    private let load: Loader
    private let cache: SwiftOrgReleaseCache
    private let now: DateProvider
    private let refreshInterval: TimeInterval

    private var snapshot: Snapshot?
    private var refresh: Refresh?
    private var waiters: [UUID: CheckedContinuation<LoadOutcome, Never>] = [:]

    init() {
        self.load = Self.liveLoad
        self.cache = .live()
        self.now = Date.init
        self.refreshInterval = Self.defaultRefreshInterval
    }

    init(load: @escaping Loader) {
        self.load = load
        self.cache = SwiftOrgReleaseCache(fileURL: nil)
        self.now = Date.init
        self.refreshInterval = Self.defaultRefreshInterval
    }

    init(
        load: @escaping Loader,
        cache: SwiftOrgReleaseCache,
        now: @escaping DateProvider,
        refreshInterval: TimeInterval = SwiftOrgReleaseCatalog.defaultRefreshInterval
    ) {

        self.load = load
        self.cache = cache
        self.now = now
        self.refreshInterval = refreshInterval
    }

    /// Returns one recent validated observation and coalesces concurrent refreshes.
    func stableReleases() async throws -> [OfficialStableRelease] {

        try Task.checkCancellation()

        if let snapshot, isFresh(snapshot) { return snapshot.releases }

        let waiter = UUID()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LoadOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }

                waiters[waiter] = continuation
                beginRefreshIfNeeded()
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter) }
        }

        try Task.checkCancellation()

        switch outcome {
            case .success(_, let releases): return releases
            case .networkFailure: throw CatalogError.networkFailure
            case .invalidPayload: throw CatalogError.invalidPayload
            case .cancelled: throw CancellationError()
        }
    }

    /// Returns a previously validated observation without making a network request.
    func cachedReleases() -> [OfficialStableRelease]? {

        if let snapshot { return snapshot.releases }
        guard let data = try? cache.read() else { return nil }

        return try? Self.parse(data)
    }

}

extension SwiftOrgReleaseCatalog {

    private func isFresh(_ snapshot: Snapshot) -> Bool {

        let age = now().timeIntervalSince(snapshot.loadedAt)
        return age >= 0 && age < refreshInterval
    }

    private func beginRefreshIfNeeded() {

        guard refresh == nil else { return }

        let identifier = UUID()
        let load = load
        let task = Task.detached { [weak self] in
            let outcome = await Self.loadObservation(using: load)
            await self?.finishRefresh(identifier, with: outcome)
        }

        refresh = Refresh(identifier: identifier, task: task)
    }

    private func finishRefresh(_ identifier: UUID, with outcome: LoadOutcome) {

        guard refresh?.identifier == identifier else { return }

        refresh = nil

        if case .success(let data, let releases) = outcome {
            snapshot = Snapshot(
                releases: releases,
                loadedAt: now()
            )
            try? cache.write(data)
        }

        let continuations = waiters.values
        waiters.removeAll()

        for continuation in continuations {
            continuation.resume(returning: outcome)
        }
    }

    private func cancelWaiter(_ identifier: UUID) {

        guard let continuation = waiters.removeValue(forKey: identifier) else { return }

        continuation.resume(returning: .cancelled)

        if waiters.isEmpty, let refresh {
            self.refresh = nil
            refresh.task.cancel()
        }
    }

}

extension SwiftOrgReleaseCatalog {

    private static func loadObservation(using load: Loader) async -> LoadOutcome {

        do {
            try Task.checkCancellation()

            let response = try await load(Self.releasesURL)
            try Task.checkCancellation()

            guard response.statusCode == 200 else { return .networkFailure }

            let releases = try Self.parse(response.data)
            return .success(data: response.data, releases: releases)
        } catch is CancellationError {
            return .cancelled
        } catch CatalogError.invalidPayload {
            return .invalidPayload
        } catch {
            if Task.isCancelled { return .cancelled }
            return .networkFailure
        }
    }

    /// Narrows Swift.org's evolving public schema to exact stable toolchain and SDK pairs.
    private static func parse(_ data: Data) throws -> [OfficialStableRelease] {

        let payloads: [ReleasePayload]
        do { payloads = try JSONDecoder().decode([ReleasePayload].self, from: data) }
        catch { throw CatalogError.invalidPayload }

        return payloads.compactMap(release(from:))
    }

    private static func release(from payload: ReleasePayload) -> OfficialStableRelease? {

        guard let name = payload.name else { return nil }
        guard let version = SwiftVersion(name) else { return nil }
        guard payload.tag == "swift-\(name)-RELEASE" else { return nil }

        guard let platform = payload.platforms?.first(where: { $0.platform == "static-sdk" }) else { return nil }
        guard let sdkVersion = platform.version else { return nil }
        guard SwiftVersion(sdkVersion) != nil else { return nil }
        guard let checksum = platform.checksum else { return nil }

        let architectures = Set((platform.archs ?? []).compactMap(LinuxArchitecture.init(catalogName:)))

        let identifier = "swift-\(name)-RELEASE_static-linux-\(sdkVersion)"
        let releaseDirectory = "swift-\(name.lowercased())-release"
        let filename = "\(identifier).artifactbundle.tar.gz"
        let downloadDirectoryURL = "https://download.swift.org/\(releaseDirectory)/static-sdk"
        let downloadURLString = "\(downloadDirectoryURL)/swift-\(name)-RELEASE/\(filename)"

        guard let downloadURL = URL(string: downloadURLString) else { return nil }

        let sdk = StaticLinuxSDK(
            identifier: identifier,
            version: sdkVersion
        )
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

    struct Response: Sendable {
        let data: Data
        let statusCode: Int?
    }

    enum CatalogError: Error, Sendable {
        case networkFailure
        case invalidPayload
    }

    private struct Snapshot: Sendable {
        let releases: [OfficialStableRelease]
        let loadedAt: Date
    }

    private struct Refresh: Sendable {
        let identifier: UUID
        let task: Task<Void, Never>
    }

    private enum LoadOutcome: Sendable {
        case success(data: Data, releases: [OfficialStableRelease])
        case networkFailure
        case invalidPayload
        case cancelled
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

extension SwiftOrgReleaseCatalog {

    static let shared = SwiftOrgReleaseCatalog()

    private static let defaultRefreshInterval: TimeInterval = 60 * 60
    private static let releasesURL = URL(string: "https://www.swift.org/api/v1/install/releases.json")!
}
