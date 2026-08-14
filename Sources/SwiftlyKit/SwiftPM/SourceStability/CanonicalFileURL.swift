import Foundation

/// Canonical local file URL that resolves symbolic links in existing path prefixes.
enum CanonicalFileURL {

    /// Returns one absolute URL and preserves trailing components that do not exist.
    static func resolve(_ url: URL) throws -> URL {

        guard url.isFileURL else { throw Error.notFileURL }

        var pendingComponents = Array(url.standardized.pathComponents.dropFirst())
        var resolved = URL(filePath: "/", directoryHint: .isDirectory)
        var symbolicLinkCount = 0

        while !pendingComponents.isEmpty {
            let component = pendingComponents.removeFirst()
            let candidate = resolved.appending(path: component)

            guard let destination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: candidate.path(percentEncoded: false)
            ) else {
                resolved = candidate
                continue
            }

            symbolicLinkCount += 1
            guard symbolicLinkCount <= maximumSymbolicLinkCount else { throw Error.symbolicLinkLoop }

            let destinationURL = if destination.hasPrefix("/") {
                URL(filePath: destination, directoryHint: .inferFromPath)
            } else {
                resolved.appending(path: destination, directoryHint: .inferFromPath)
            }
            pendingComponents = Array(destinationURL.standardized.pathComponents.dropFirst())
                + pendingComponents
            resolved = URL(filePath: "/", directoryHint: .isDirectory)
        }

        return resolved.standardized
    }

}

extension CanonicalFileURL {

    enum Error: Swift.Error {
        case notFileURL
        case symbolicLinkLoop
    }

    private static let maximumSymbolicLinkCount = 64

}
