import Foundation

/// Disposable storage for one validated raw Swift.org release catalog.
struct SwiftOrgReleaseCache: Sendable {

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Returns the cached payload only if its path contains a bounded regular file.
    func read() throws -> Data? {

        guard let fileURL else { return nil }

        let directoryURL = fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directoryURL.path(percentEncoded: false)) else { return nil }

        try validateDirectory(directoryURL)

        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }

        let values = try fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])

        guard values.isSymbolicLink != true else { throw CacheError.unsafePath }
        guard values.isRegularFile == true else { throw CacheError.unsafePath }
        guard let size = values.fileSize else { throw CacheError.invalidPayload }
        guard size <= Self.maximumPayloadSize else { throw CacheError.invalidPayload }

        return try Data(contentsOf: fileURL)
    }

    /// Atomically replaces the cache with one bounded payload and private permissions.
    func write(_ data: Data) throws {

        guard let fileURL else { return }
        guard data.count <= Self.maximumPayloadSize else { throw CacheError.invalidPayload }

        let directoryURL = fileURL.deletingLastPathComponent()
        try createDirectoryIfNeeded(directoryURL)

        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])

            guard values.isSymbolicLink != true else { throw CacheError.unsafePath }
            guard values.isRegularFile == true else { throw CacheError.unsafePath }
        }

        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path(percentEncoded: false)
        )
    }

}

extension SwiftOrgReleaseCache {

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

    private func validateDirectory(_ directoryURL: URL) throws {

        let values = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])

        guard values.isSymbolicLink != true else { throw CacheError.unsafePath }
        guard values.isDirectory == true else { throw CacheError.unsafePath }
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

    private enum CacheError: Error {
        case invalidPayload
        case unsafePath
    }

    private static let maximumPayloadSize = 4 * 1024 * 1024
}
