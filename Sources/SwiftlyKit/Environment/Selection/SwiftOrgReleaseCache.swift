import Foundation

/// Disposable storage for one validated raw Swift.org release catalog.
struct SwiftOrgReleaseCache: Sendable {

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Returns the cached payload only if its path contains a bounded regular file.
    func read() throws -> Data? {

        try readObservation()?.data
    }

    /// Associates raw data with its original atomic snapshot time. Missing times cannot authorize fresh reuse.
    func readObservation() throws -> Observation? {

        guard var fileURL else { return nil }
        fileURL.removeAllCachedResourceValues()

        let directoryURL = fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directoryURL.path(percentEncoded: false)) else { return nil }

        try validateDirectory(directoryURL)

        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }

        let values = try fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ])

        guard values.isSymbolicLink != true,
              values.isRegularFile == true
        else { throw CacheError.unsafePath }
        guard let size = values.fileSize else { throw CacheError.invalidPayload }
        guard size >= 0, size <= Self.maximumPayloadSize else { throw CacheError.invalidPayload }

        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumPayloadSize else { throw CacheError.invalidPayload }
        fileURL.removeAllCachedResourceValues()
        let current = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard current.fileSize == values.fileSize,
              current.contentModificationDate == values.contentModificationDate
        else { return nil }
        return Observation(data: data, modifiedAt: values.contentModificationDate)
    }

    /// Atomically replaces the cache with one bounded payload and private permissions.
    func write(_ data: Data, observedAt: Date? = nil) throws {

        guard let fileURL else { return }
        guard data.count <= Self.maximumPayloadSize else { throw CacheError.invalidPayload }

        let directoryURL = fileURL.deletingLastPathComponent()
        try createDirectoryIfNeeded(directoryURL)

        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])

            guard values.isSymbolicLink != true,
                  values.isRegularFile == true
            else { throw CacheError.unsafePath }
        }

        try data.write(to: fileURL, options: .atomic)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if let observedAt { attributes[.modificationDate] = observedAt }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path(percentEncoded: false))
    }

}

extension SwiftOrgReleaseCache {

    private func validateDirectory(_ directoryURL: URL) throws {

        let values = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])

        guard values.isSymbolicLink != true,
              values.isDirectory == true
        else { throw CacheError.unsafePath }
    }

    private func createDirectoryIfNeeded(_ directoryURL: URL) throws {

        if !FileManager.default.fileExists(atPath: directoryURL.path(percentEncoded: false)) {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                guard FileManager.default.fileExists(atPath: directoryURL.path(percentEncoded: false)) else {
                    throw error
                }
            }
        }

        try validateDirectory(directoryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path(percentEncoded: false)
        )
    }

}

extension SwiftOrgReleaseCache {

    /// Returns the cache location for the current user or disables persistence if no cache directory exists.
    static func live() -> SwiftOrgReleaseCache {

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        guard let root = caches.first else { return SwiftOrgReleaseCache(fileURL: nil) }

        let directory = root.appending(path: "SwiftlyKit", directoryHint: .isDirectory)
        let file = directory.appending(path: "swift-org-releases-v1.json", directoryHint: .notDirectory)

        return SwiftOrgReleaseCache(fileURL: file)
    }

}

extension SwiftOrgReleaseCache {

    struct Observation: Sendable {
        let data: Data
        let modifiedAt: Date?
    }

    private enum CacheError: Error {
        case invalidPayload
        case unsafePath
    }

    private static let maximumPayloadSize = 4 * 1024 * 1024
}
